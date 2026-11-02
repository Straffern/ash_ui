defmodule AshUi.Datastar.RenderTarget do
  @moduledoc """
  Datastar lowering for AshUi's target-neutral HTML contract.

  Every materialized element receives a deterministic id derived from its
  compiled address and runtime keyed-entry chain. Authored ids always win.
  """

  use AshUi.RenderTarget

  alias AshUi.RenderTree.{Element, Fragment, Portal, Text}

  @base_path_marker "__ASH_UI_BASE_PATH__"
  @client_header_option "headers: {'ash-ui-client-id': globalThis.__ashUiDatastarClientId}"

  @impl AshUi.RenderTarget
  def attr_name(key) do
    key = to_string(key)

    cond do
      key == "data-ash-ui-binding" ->
        "data-ash-ui-binding"

      key == "data-ash-ui-client-hook" ->
        "data-ash-ui-client-hook"

      key == "data-ash-ui-dom-update" ->
        "data-ignore-morph"

      key == "data-ash-ui-change" ->
        "data-on:change"

      key == "data-ash-ui-submit" ->
        "data-on:submit"

      key == "data-ash-ui-on-click-away" ->
        "data-on:click__outside"

      String.starts_with?(key, "data-ash-ui-on-") ->
        "data-on:" <> String.replace_prefix(key, "data-ash-ui-on-", "")

      true ->
        key
    end
  end

  @impl AshUi.RenderTarget
  def finalize_attrs(attrs, tag, meta, events) do
    attrs
    |> lower_event_payloads(tag, events)
    |> lower_navigation_attrs(tag, meta, events)
    |> strip_binding_attrs()
  end

  @impl AshUi.RenderTarget
  def finalize_skeleton_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn {key, _value}, kept ->
      if to_string(key) == "id", do: Map.put(kept, key, ""), else: kept
    end)
  end

  @impl AshUi.RenderTarget
  def dispatch_event_value(binding_key) do
    encoded = URI.encode(binding_key, &URI.char_unreserved?/1)

    "@post('/_ash_ui/dispatch/#{encoded}', {#{@client_header_option}})"
  end

  @impl AshUi.RenderTarget
  def finalize_tree(nil), do: nil

  def finalize_tree(tree) do
    tree |> lower_screen_navigation() |> put_ids()
  end

  @impl AshUi.RenderTarget
  def preserve_component_boundaries?, do: true

  @impl AshUi.RenderTarget
  def runtime_chain_attrs?, do: true

  @impl AshUi.RenderTarget
  def finalize_materialized_attrs(%{kind: :element} = element) do
    element =
      Map.update!(element, :attrs, fn attrs ->
        lower_navigation_attrs(
          attrs,
          Map.get(element, :tag),
          Map.get(element, :meta, %{}),
          Map.get(element, :events, [])
        )
      end)

    meta = Map.get(element, :meta, %{})
    address = Map.get(meta, :__bp_addr__)
    chain = Map.get(meta, :__bp_runtime_chain__, [])

    attrs =
      element
      |> Map.get(:attrs, %{})
      |> maybe_put_id(address, chain)
      |> maybe_put_signal_binding(
        Map.get(element, :tag),
        Map.get(element, :events, []),
        meta
      )
      |> strip_binding_attrs()

    Map.put(element, :attrs, attrs)
  end

  def finalize_materialized_attrs(element), do: element

  @doc false
  def base_path_marker, do: @base_path_marker

  @doc false
  def popstate_expression do
    "@get(window.location.pathname + window.location.search, " <>
      "{payload: {}, retry: 'never'})"
  end

  @doc false
  def dom_id(address, chain \\ []) when is_binary(address) and is_list(chain) do
    boundary = boundary_address(address)

    # 10 url-base64 chars = 60 bits — ids only need uniqueness within one
    # document, and at collection scale the id is per-element wire/DOM mass.
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary({boundary, chain}))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 10)

    "bp-" <> hash
  end

  defp put_ids(%Element{} = element) do
    meta = element.meta || %{}
    address = Map.get(meta, :__bp_addr__)
    chain = Map.get(meta, :__bp_runtime_chain__, [])

    attrs =
      element.attrs
      |> maybe_put_id(address, chain)
      |> maybe_put_signal_binding(element)

    %Element{element | attrs: attrs, children: Enum.map(element.children, &put_ids/1)}
  end

  defp put_ids(%Fragment{} = fragment),
    do: %Fragment{fragment | children: Enum.map(fragment.children, &put_ids/1)}

  defp put_ids(%Portal{} = portal),
    do: %Portal{portal | children: Enum.map(portal.children, &put_ids/1)}

  defp put_ids(%Text{} = text), do: text
  defp put_ids(other), do: other

  defp lower_screen_navigation(%Element{} = element) do
    children = Enum.map(element.children, &lower_screen_navigation/1)

    attrs =
      lower_navigation_attrs(element.attrs, element.tag, element.meta, element.event_bindings)

    %Element{element | attrs: attrs, children: children}
  end

  defp lower_screen_navigation(%Fragment{} = fragment),
    do: %Fragment{fragment | children: Enum.map(fragment.children, &lower_screen_navigation/1)}

  defp lower_screen_navigation(%Portal{} = portal),
    do: %Portal{portal | children: Enum.map(portal.children, &lower_screen_navigation/1)}

  defp lower_screen_navigation(nodes) when is_list(nodes),
    do: Enum.map(nodes, &lower_screen_navigation/1)

  defp lower_screen_navigation(other), do: other

  defp lower_event_payloads(attrs, tag, events) do
    Enum.reduce(events, attrs, fn binding, attrs ->
      fields = minimal_payload_fields(binding, tag, attrs)

      if fields == [] do
        attrs
      else
        event = event_name(binding.dom_event)
        binding_key = Map.get(attrs, "data-ash-ui-binding-#{event}")

        if is_binary(binding_key) do
          encoded = URI.encode(binding_key, &URI.char_unreserved?/1)

          Map.put(
            attrs,
            "data-ash-ui-on-#{event}",
            "@post('/_ash_ui/dispatch/#{encoded}', " <>
              "{#{@client_header_option}, payload: #{payload_expression(fields)}, " <>
              "retry: 'never'})"
          )
        else
          attrs
        end
      end
    end)
  end

  # the payload carries only what dispatch can consume: fields the binding's
  # own expressions reference via event(:field), plus the kind's required
  # transport (the value source for field-name binding; the form on submit)
  defp minimal_payload_fields(binding, tag, attrs) do
    declared =
      binding
      |> Map.from_struct()
      |> AshUi.EventBinding.payload_fields()
      |> Enum.filter(&AshUi.EventBinding.payload_field?(binding.dom_event, &1))

    required =
      case event_name(binding.dom_event) do
        "submit" <> _rest ->
          [:form]

        "reorder" ->
          [:order]

        event when binary_part(event, 0, min(byte_size(event), 5)) in ["input", "chang"] ->
          # a container binding (form/div) receives BUBBLED events: the
          # changing control is evt.target, unknown at compile — ship the
          # value subset; a direct control binding ships its own source
          case AshUi.EventBinding.value_source_for(tag, attrs, binding.dom_event) do
            nil -> [:value, :checked, :selected_options]
            source -> [source]
          end

        _other ->
          []
      end

    Enum.uniq(required ++ declared)
  end

  defp payload_expression(fields) do
    fields
    |> Enum.map_join(", ", fn field ->
      Jason.encode!(Atom.to_string(field)) <> ": " <> payload_field_expression(field)
    end)
    |> then(&"{#{&1}}")
  end

  defp payload_field_expression(:value), do: "evt.target.value"
  defp payload_field_expression(:checked), do: "!!evt.target.checked"

  defp payload_field_expression(:selected_options),
    do: "Array.from(evt.target.selectedOptions || []).map(option => option.value)"

  defp payload_field_expression(:form) do
    "(evt.target.form || evt.target.tagName === 'FORM') ? " <>
      "Array.from(new FormData(evt.target.form || evt.target).entries()).reduce(" <>
      "(form, [name, value]) => (form[name] = name in form ? " <>
      "[...[].concat(form[name]), value] : value, form), {}) : {}"
  end

  defp payload_field_expression(:key), do: "evt.key"
  defp payload_field_expression(:alt), do: "!!evt.altKey"
  defp payload_field_expression(:ctrl), do: "!!evt.ctrlKey"
  defp payload_field_expression(:meta), do: "!!evt.metaKey"
  defp payload_field_expression(:shift), do: "!!evt.shiftKey"
  defp payload_field_expression(:button), do: "evt.button"
  defp payload_field_expression(:buttons), do: "evt.buttons"
  defp payload_field_expression(:client_x), do: "evt.clientX"
  defp payload_field_expression(:client_y), do: "evt.clientY"
  defp payload_field_expression(:page_x), do: "evt.pageX"
  defp payload_field_expression(:page_y), do: "evt.pageY"
  defp payload_field_expression(:screen_x), do: "evt.screenX"
  defp payload_field_expression(:screen_y), do: "evt.screenY"
  defp payload_field_expression(:order), do: "evt.detail && evt.detail.order"

  defp event_name(event) when is_atom(event),
    do: event |> Atom.to_string() |> String.replace("_", "-")

  defp event_name("data-ash-ui-on-" <> event), do: event
  defp event_name(event), do: to_string(event)

  defp strip_binding_attrs(attrs) do
    Map.drop(attrs, Enum.filter(Map.keys(attrs), &binding_attr?/1))
  end

  defp binding_attr?(key) do
    key = to_string(key)

    key == "data-bind" or key == "data-ash-ui-binding" or
      String.starts_with?(key, "data-ash-ui-binding-")
  end

  defp lower_navigation_attrs(attrs, tag, meta, events) do
    href = Map.get(attrs, "href", Map.get(attrs, :href))

    kind =
      cond do
        tag not in [:a, "a"] -> nil
        lowered = lowered_navigation_kind(attrs) -> lowered
        explicit = navigation_kind(meta) -> explicit
        Map.get(meta, :screen_navigation?) -> inferred_navigation_kind(meta, href)
        true -> nil
      end

    case kind do
      kind when kind in [:patch, :redirect] ->
        target = browser_target(href)
        attrs = Map.put(attrs, "href", target)

        if native_click?(attrs, events) do
          attrs
        else
          history = if navigation_state(meta) == :replace, do: "replaceState", else: "pushState"

          expression =
            "evt.button !== 0 || evt.metaKey || evt.ctrlKey || evt.shiftKey || evt.altKey || " <>
              "(evt.preventDefault(), history.#{history}({}, '', #{Jason.encode!(target)}), " <>
              "@get(#{Jason.encode!(target)}, {payload: {}, retry: 'never'}))"

          attrs
          |> Map.put_new("data-on:click", expression)
          |> Map.put_new("data-ash-ui-link", Atom.to_string(kind))
          |> Map.put_new(
            "data-ash-ui-link-state",
            Atom.to_string(navigation_state(meta))
          )
        end

      _native ->
        attrs
    end
  end

  defp lowered_navigation_kind(attrs) do
    case Map.get(attrs, "data-ash-ui-link", Map.get(attrs, :"data-ash-ui-link")) do
      kind when kind in [:patch, "patch"] -> :patch
      kind when kind in [:redirect, :navigate, "redirect", "navigate"] -> :redirect
      _none -> nil
    end
  end

  defp navigation_kind(meta) do
    case get_in(meta, [:navigation, :kind]) || get_in(meta, ["navigation", "kind"]) do
      kind when kind in [:patch, "patch"] -> :patch
      kind when kind in [:redirect, :navigate, "redirect", "navigate"] -> :redirect
      _none -> nil
    end
  end

  defp inferred_navigation_kind(meta, href) do
    AshUi.Location.navigation_kind(
      %{
        all: Map.get(meta, :screen_navigation_routes, []),
        patch: Map.get(meta, :screen_navigation_patch_routes, [])
      },
      href
    )
  end

  defp navigation_state(meta) do
    case get_in(meta, [:navigation, :state]) || get_in(meta, ["navigation", "state"]) do
      state when state in [:replace, "replace"] -> :replace
      _push -> :push
    end
  end

  defp native_click?(attrs, events) do
    Map.has_key?(attrs, "target") or
      Map.has_key?(attrs, :target) or
      Map.has_key?(attrs, "download") or
      Map.has_key?(attrs, :download) or
      Enum.any?(events, &(Map.get(&1, :dom_event) in [:click, "click"]))
  end

  defp browser_target("/" <> _rest = href), do: @base_path_marker <> href
  defp browser_target(href), do: href

  defp maybe_put_id(attrs, nil, _chain), do: attrs

  defp maybe_put_id(attrs, address, chain) do
    if Map.has_key?(attrs, "id") or Map.has_key?(attrs, :id) do
      attrs
    else
      Map.put(attrs, "id", dom_id(address, chain))
    end
  end

  # Bound form controls expose their value as a Datastar signal. The signal
  # name is AshUi's binding key; it is transport input only and is never
  # treated as application state.
  defp maybe_put_signal_binding(attrs, %Element{tag: tag, event_bindings: bindings, meta: meta})
       when tag in [:input, :textarea, :select, "input", "textarea", "select"] do
    maybe_put_signal_binding(attrs, tag, bindings, meta)
  end

  defp maybe_put_signal_binding(attrs, _element), do: attrs

  defp maybe_put_signal_binding(attrs, tag, bindings, meta)
       when tag in [:input, :textarea, :select, "input", "textarea", "select"] do
    case bindings do
      [%{dom_event: event} | _] when event in [:input, :change, "input", "change"] ->
        case Map.get(meta || %{}, :__bp_binding_chain__) do
          [_ | _] = chain ->
            key = Enum.join(chain ++ [AshUi.EventBinding.event_key_component(event)], ".")
            Map.put_new(attrs, "data-bind", key)

          _missing ->
            attrs
        end

      _other ->
        attrs
    end
  end

  defp maybe_put_signal_binding(attrs, _tag, _bindings, _meta), do: attrs

  # Both arms of a branch and the root of a keyed template represent the
  # same browser boundary over time. Their runtime chain distinguishes keyed
  # entries; their arm marker must not change the id on a branch flip.
  defp boundary_address(address) do
    base =
      if String.ends_with?(address, "/t/0") or String.ends_with?(address, "/f/0") do
        binary_part(address, 0, byte_size(address) - 4)
      else
        address
      end

    if String.ends_with?(base, "/*/0") do
      binary_part(base, 0, byte_size(base) - 4)
    else
      base
    end
  end
end
