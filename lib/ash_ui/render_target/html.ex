defmodule AshUi.RenderTarget.Html do
  @moduledoc """
  Host-neutral HTML target lowering for `AshUi.RenderTree`.

  Live HTML adapters, static HTML, and future HTML-like hosts should consume this target
  contract instead of reinterpreting semantic render-tree metadata themselves.
  """

  alias AshUi.{AttrMerge, EventBinding}
  alias AshUi.Expr.Blank
  alias AshUi.RenderTree
  alias AshUi.SafeHTML

  @void_tags ~w(area base br col embed hr img input link meta param source track wbr)

  @spec attrs(RenderTree.Element.t(), keyword()) :: map()
  def attrs(%RenderTree.Element{} = element, opts \\ []) do
    attrs_for(
      element.tag,
      element.attrs,
      element.event_bindings,
      element.meta,
      Keyword.put_new(opts, :node_path, RenderTree.Path.root_path(element))
    )
  end

  @spec attrs_for(atom() | String.t() | nil, map(), [EventBinding.t()], map(), keyword()) :: map()
  def attrs_for(tag, attrs, events, meta, opts \\ [])
      when is_map(attrs) and is_list(events) and is_map(meta) and is_list(opts) do
    do_attrs_for(
      tag,
      attrs,
      events,
      meta,
      Keyword.get(opts, :target, AshUi.RenderTarget.Static),
      Keyword.get(opts, :node_path, [])
    )
  end

  defp do_attrs_for(tag, attrs, events, meta, target, node_path) do
    attrs
    |> merge_part_contract(tag, meta)
    |> merge_state_attrs(meta)
    |> merge_event_bindings(events, node_path, meta, target)
    |> merge_client_action_mount(meta)
    |> merge_client_runtime_mount(meta)
    |> merge_dom_owner_lowering(meta)
    |> merge_navigation_lowering(meta)
    |> merge_inferred_navigation_lowering(tag, meta)
    |> merge_route_patch_form_lowering(meta)
    |> target.finalize_attrs(tag, meta, events)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      original_key = attr_name(key)

      if drop_attr_value?(original_key, value) do
        acc
      else
        Map.put(acc, target.attr_name(original_key), serialize_attr_value(original_key, value))
      end
    end)
  end

  @spec render_static(term(), keyword()) :: {:safe, iodata()}
  def render_static(tree, opts \\ []) when is_list(opts) do
    # target is constant for the whole tree: thread it positionally instead
    # of rebuilding keyword lists per element
    target = Keyword.get(opts, :target, AshUi.RenderTarget.Static)
    {:safe, render_static_node(tree, target, RenderTree.Path.root_path(tree))}
  end

  @spec html_escape(term()) :: iodata()
  # Small values stay on the allocation-free byte walker used by row-heavy
  # views. Large text nodes use the VM's compiled multi-pattern scan, then
  # become sub-binary iodata around the matched bytes. This keeps clean
  # document text off an Elixir recursion per byte without penalising the
  # many short values in collection renders.
  def html_escape(content) do
    content = to_string(content)

    if byte_size(content) < 128 do
      escape_binary(content, 0, content, [], 0)
    else
      escape_matches(content, :binary.matches(content, ["&", "<", ">", "\"", "'"]), 0, [])
    end
  end

  @spec html_text_escape(term()) :: iodata()
  # Quotes are only special inside attributes. Keeping them literal in text
  # nodes avoids constructing tens of thousands of needless entities in
  # prose-heavy documents while retaining the HTML-significant escapes.
  def html_text_escape(content) do
    content = to_string(content)

    if byte_size(content) < 128 do
      escape_text_binary(content, 0, content, [], 0)
    else
      content
      |> :binary.replace("&", "&amp;", [:global])
      |> :binary.replace("<", "&lt;", [:global])
    end
  end

  @html_escapes [{?&, "&amp;"}, {?<, "&lt;"}, {?>, "&gt;"}, {?", "&quot;"}, {?', "&#39;"}]

  for {match, insert} <- @html_escapes do
    defp escape_binary(<<unquote(match), rest::binary>>, skip, original, acc, len) do
      part = binary_part(original, skip, len)
      escape_binary(rest, skip + len + 1, original, [acc, part | unquote(insert)], 0)
    end
  end

  defp escape_binary(<<_byte, rest::binary>>, skip, original, acc, len) do
    escape_binary(rest, skip, original, acc, len + 1)
  end

  defp escape_binary(<<>>, 0, original, [], _len), do: original

  defp escape_binary(<<>>, skip, original, acc, len) do
    [acc | binary_part(original, skip, len)]
  end

  defp escape_matches(content, [], cursor, acc) do
    tail = binary_part(content, cursor, byte_size(content) - cursor)
    Enum.reverse([tail | acc])
  end

  defp escape_matches(content, [{offset, 1} | matches], cursor, acc) do
    segment = binary_part(content, cursor, offset - cursor)
    replacement = escape_match(:binary.at(content, offset))
    escape_matches(content, matches, offset + 1, [replacement, segment | acc])
  end

  defp escape_match(?&), do: "&amp;"
  defp escape_match(?<), do: "&lt;"
  defp escape_match(?>), do: "&gt;"
  defp escape_match(?"), do: "&quot;"
  defp escape_match(?'), do: "&#39;"

  @html_text_escapes [{?&, "&amp;"}, {?<, "&lt;"}]

  for {match, insert} <- @html_text_escapes do
    defp escape_text_binary(<<unquote(match), rest::binary>>, skip, original, acc, len) do
      part = binary_part(original, skip, len)
      escape_text_binary(rest, skip + len + 1, original, [acc, part | unquote(insert)], 0)
    end
  end

  defp escape_text_binary(<<_byte, rest::binary>>, skip, original, acc, len) do
    escape_text_binary(rest, skip, original, acc, len + 1)
  end

  defp escape_text_binary(<<>>, 0, original, [], _len), do: original

  defp escape_text_binary(<<>>, skip, original, acc, len) do
    [acc | binary_part(original, skip, len)]
  end

  @spec safe_to_iodata(term()) :: iodata()
  def safe_to_iodata(nil), do: []
  def safe_to_iodata({:safe, iodata}), do: iodata
  def safe_to_iodata(%SafeHTML{iodata: iodata}), do: iodata
  def safe_to_iodata(%RenderTree.Element{} = tree), do: tree_iodata(tree)
  def safe_to_iodata(%RenderTree.Text{} = tree), do: tree_iodata(tree)
  def safe_to_iodata(%RenderTree.Fragment{} = tree), do: tree_iodata(tree)
  def safe_to_iodata(%RenderTree.Portal{} = tree), do: tree_iodata(tree)
  def safe_to_iodata(content) when is_list(content), do: Enum.map(content, &safe_to_iodata/1)
  def safe_to_iodata(content), do: html_text_escape(content)

  @spec safe_text(term()) :: {:safe, iodata()}
  def safe_text(content), do: {:safe, safe_to_iodata(text_content(content))}

  @spec render_tree_value?(term()) :: boolean()
  def render_tree_value?(%RenderTree.Element{}), do: true
  def render_tree_value?(%RenderTree.Fragment{}), do: true
  def render_tree_value?(%RenderTree.Text{}), do: true
  def render_tree_value?(%RenderTree.Portal{}), do: true
  def render_tree_value?(_value), do: false

  @spec attributes_iodata(map() | keyword()) :: iodata()
  def attributes_iodata(attrs) when is_map(attrs),
    do: attrs |> Map.to_list() |> attributes_iodata()

  def attributes_iodata(attrs) when is_list(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> value in [nil, false] end)
    |> Enum.map(fn
      {key, true} ->
        [" ", attr_name(key)]

      {key, value} ->
        [" ", attr_name(key), "=\"", attr_value(value), "\""]
    end)
  end

  @doc false
  def dynamic_attribute_iodata(original_name, target_name, value) do
    if drop_attr_value?(original_name, value) do
      []
    else
      attributes_iodata([{target_name, serialize_attr_value(original_name, value)}])
    end
  end

  defp render_static_node(nil, _target, _path), do: []

  defp render_static_node(nodes, target, path) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {child, index} ->
      render_static_node(
        child,
        target,
        RenderTree.Path.child_path(path, child, index)
      )
    end)
  end

  defp render_static_node(%RenderTree.Fragment{children: children}, target, path),
    do: render_static_node(children, target, path)

  defp render_static_node(%RenderTree.Portal{children: children}, target, path),
    do: render_static_node(children, target, path)

  defp render_static_node(%RenderTree.Text{content: content}, _target, _path),
    do: safe_to_iodata(text_content(content))

  defp render_static_node(
         %RenderTree.Element{tag: nil, children: children},
         target,
         path
       ),
       do: render_static_node(children, target, path)

  defp render_static_node(%RenderTree.Element{} = element, target, path) do
    tag = to_string(element.tag)

    attrs_iodata =
      element.tag
      |> do_attrs_for(element.attrs, element.event_bindings, element.meta, target, path)
      |> attributes_iodata()

    cond do
      tag in @void_tags ->
        ["<", tag, attrs_iodata, ">"]

      style = style_content(element, tag) ->
        ["<", tag, attrs_iodata, ">", style, "</", tag, ">"]

      textarea = textarea_content(element) ->
        ["<", tag, attrs_iodata, ">", safe_to_iodata(textarea), "</", tag, ">"]

      true ->
        [
          "<",
          tag,
          attrs_iodata,
          ">",
          render_static_node(element.children, target, path),
          "</",
          tag,
          ">"
        ]
    end
  end

  defp render_static_node(content, _target, _path), do: safe_to_iodata(content)

  defp textarea_content(%RenderTree.Element{tag: tag, children: children})
       when tag in [:textarea, "textarea"] do
    children
    |> Enum.map(&render_text_content/1)
    |> IO.iodata_to_binary()
  end

  defp textarea_content(_element), do: nil

  defp render_text_content(%RenderTree.Text{content: content}), do: text_to_string(content)

  defp render_text_content(%RenderTree.Fragment{children: children}),
    do: Enum.map(children, &render_text_content/1)

  defp render_text_content(%RenderTree.Element{children: children}),
    do: Enum.map(children, &render_text_content/1)

  defp render_text_content(content) when is_binary(content), do: content
  defp render_text_content(_other), do: ""

  defp style_content(%RenderTree.Element{children: children}, "style") do
    Enum.map_join(children, fn
      %RenderTree.Text{content: content} -> text_to_string(content)
      _other -> ""
    end)
  end

  defp style_content(_element, _tag), do: nil

  def text_content({:safe, iodata}), do: {:safe, iodata}
  def text_content(%SafeHTML{} = safe), do: safe
  def text_content(%RenderTree.Element{} = tree), do: tree
  def text_content(%RenderTree.Text{} = tree), do: tree
  def text_content(%RenderTree.Fragment{} = tree), do: tree
  def text_content(%RenderTree.Portal{} = tree), do: tree
  def text_content(content), do: text_to_string(content)

  defp tree_iodata(tree) do
    {:safe, iodata} = render_static(tree)
    iodata
  end

  defp text_to_string(content) do
    if Blank.blank?(content), do: "", else: to_string(content)
  end

  defp attr_name(value) when is_atom(value), do: kebab_atom(value)

  defp attr_name(value) when is_binary(value), do: value

  defp attr_name(value), do: to_string(value)

  defp kebab_atom(atom), do: atom |> Atom.to_string() |> String.replace("_", "-")

  defp attr_value(value) when is_list(value),
    do: value |> AttrMerge.join_attr_tokens() |> html_escape()

  defp attr_value(%SafeHTML{} = safe), do: safe_to_iodata(safe)
  defp attr_value({:safe, _iodata} = safe), do: safe_to_iodata(safe)
  defp attr_value(nil), do: []
  defp attr_value(""), do: []
  defp attr_value(%Ash.NotLoaded{}), do: []
  defp attr_value(value), do: html_escape(value)

  # ARIA-first state attributes (same vocabulary RenderTree.render applies
  # on the semantic path — the attrs chunk must be byte-equal):
  # selected/open/disabled -> aria-*, custom states -> data-*.
  defp merge_state_attrs(attrs, meta) do
    meta
    |> Map.get(:component_part_states, [])
    |> List.wrap()
    |> Enum.reduce(attrs, fn
      :selected, acc ->
        Map.put(acc, "aria-selected", "true")

      :open, acc ->
        Map.put(acc, "aria-expanded", "true")

      :disabled, acc ->
        Map.put(acc, "aria-disabled", "true")

      state, acc when is_atom(state) ->
        Map.put(acc, "data-" <> kebab_atom(state), "true")

      state, acc when is_binary(state) ->
        Map.put(acc, "data-#{String.replace(state, "_", "-")}", "true")

      _other, acc ->
        acc
    end)
  end

  defp merge_event_bindings(attrs, events, node_path, meta, target) do
    if is_map(Map.get(meta, :island)) do
      merge_island_event_bindings(attrs, events, node_path, meta)
    else
      Enum.reduce(events, attrs, fn %EventBinding{} = binding, acc ->
        binding_key = binding_key(meta, node_path, binding)

        acc
        |> Map.put(event_attr(binding), dispatch_event_value(target, binding_key))
        |> Map.put("data-ash-ui-binding", binding_key)
        |> Map.put("data-ash-ui-binding-#{event_name(binding.dom_event)}", binding_key)
        |> maybe_put_key_filter(binding)
        |> maybe_put_binding_options(binding)
      end)
    end
  end

  defp merge_island_event_bindings(attrs, events, node_path, meta) do
    bindings =
      Map.new(events, fn %EventBinding{meta: binding_meta} = binding ->
        {Map.fetch!(binding_meta, :island_event), binding_key(meta, node_path, binding)}
      end)

    Map.put(attrs, "data-ash-ui-island-events", bindings)
  end

  defp dispatch_event_value(target, binding_key) do
    if Code.ensure_loaded?(target) and function_exported?(target, :dispatch_event_value, 1) do
      target.dispatch_event_value(binding_key)
    else
      "ash_ui:dispatch:" <> binding_key
    end
  end

  # ONE key language: when the materializer stamped the chain (item keys +
  # child addrs + element address), the key is chain.event — identical
  # across live, static, and calculation output, and exactly what the
  # registration-free resolver accepts. Tree paths are the fallback for
  # unstamped trees only.
  defp binding_key(%{__bp_binding_chain__: chain}, _node_path, binding) do
    Enum.join(chain ++ [EventBinding.event_key_component(binding.dom_event)], ".")
  end

  defp binding_key(_meta, node_path, binding), do: EventBinding.binding_key(node_path, binding)

  defp merge_part_contract(attrs, tag, meta) do
    case inferred_part(tag, meta) do
      nil -> attrs
      part -> Map.put_new(attrs, "part", to_string(part))
    end
  end

  defp inferred_part(_tag, %{part: part}) when is_atom(part) or is_binary(part), do: part

  defp inferred_part(_tag, %{component_part: part}) when is_atom(part) or is_binary(part),
    do: part

  defp inferred_part(_tag, %{node: node}) when is_atom(node) or is_binary(node), do: node

  defp inferred_part(_tag, %{semantic: {_kind, name}})
       when is_atom(name) or is_binary(name),
       do: name

  defp inferred_part(tag, _meta) when is_atom(tag) or is_binary(tag), do: tag
  defp inferred_part(_tag, _meta), do: nil

  defp maybe_put_key_filter(attrs, %EventBinding{dom_event: dom_event, meta: meta})
       when dom_event in [:keydown, :keyup, "keydown", "keyup"] and is_map(meta) do
    case single_unmodified_key_filter(Map.get(meta, :key_filter)) do
      {:ok, key} -> Map.put_new(attrs, "data-ash-ui-key", dom_key_name(key))
      :error -> attrs
    end
  end

  defp maybe_put_key_filter(attrs, _binding), do: attrs

  defp maybe_put_binding_options(
         attrs,
         %EventBinding{meta: %{prevent_default: true, stop_propagation: true}} = binding
       ) do
    event = binding.dom_event |> event_name() |> to_string()

    attrs
    |> Map.update("data-ash-ui-prevent-default", event, &append_event_name(&1, event))
    |> Map.update("data-ash-ui-stop-propagation", event, &append_event_name(&1, event))
  end

  defp maybe_put_binding_options(attrs, %EventBinding{meta: %{prevent_default: true}} = binding) do
    event = binding.dom_event |> event_name() |> to_string()
    Map.update(attrs, "data-ash-ui-prevent-default", event, &append_event_name(&1, event))
  end

  defp maybe_put_binding_options(attrs, %EventBinding{meta: %{stop_propagation: true}} = binding) do
    event = binding.dom_event |> event_name() |> to_string()
    Map.update(attrs, "data-ash-ui-stop-propagation", event, &append_event_name(&1, event))
  end

  defp maybe_put_binding_options(attrs, _binding), do: attrs

  defp append_event_name(existing, event) when is_binary(existing) do
    existing
    |> String.split(" ", trim: true)
    |> Kernel.++([event])
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp append_event_name(_existing, event), do: event

  defp single_unmodified_key_filter(%{key: key, modifiers: modifiers})
       when modifiers in [[], nil],
       do: {:ok, key}

  defp single_unmodified_key_filter(_filter), do: :error

  defp event_attr(%EventBinding{dom_event: dom_event}), do: event_attr(dom_event)

  defp event_attr(dom_event) when is_atom(dom_event),
    do: "data-ash-ui-on-#{dom_event_name(dom_event)}"

  defp event_attr("data-ash-ui-on-" <> _ = attr), do: attr
  defp event_attr(dom_event) when is_binary(dom_event), do: "data-ash-ui-on-#{dom_event}"

  defp dom_event_name(dom_event), do: kebab_atom(dom_event)

  defp event_name(dom_event) when is_atom(dom_event), do: dom_event_name(dom_event)
  defp event_name("data-ash-ui-on-" <> event), do: event
  defp event_name(dom_event), do: to_string(dom_event)

  defp dom_key_name(:enter), do: "Enter"
  defp dom_key_name(:escape), do: "Escape"
  defp dom_key_name(:esc), do: "Escape"
  defp dom_key_name(:tab), do: "Tab"
  defp dom_key_name(:space), do: " "
  defp dom_key_name(:arrow_up), do: "ArrowUp"
  defp dom_key_name(:arrow_down), do: "ArrowDown"
  defp dom_key_name(:arrow_left), do: "ArrowLeft"
  defp dom_key_name(:arrow_right), do: "ArrowRight"
  defp dom_key_name(:context_menu), do: "ContextMenu"
  defp dom_key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp dom_key_name(key), do: to_string(key)

  defp merge_client_action_mount(attrs, %{client_actions: client_actions})
       when is_list(client_actions) and client_actions != [] do
    serialized_actions =
      client_actions
      |> Enum.map(&EventBinding.serialize_client_action/1)
      |> Enum.uniq()

    attrs
    |> Map.put_new("data-ash-ui-client-actions", Jason.encode!(serialized_actions))
    |> Map.put_new("data-ash-ui-client-hook", "AshUiClient")
  end

  defp merge_client_action_mount(attrs, _meta), do: attrs

  defp merge_client_runtime_mount(attrs, %{client_runtimes: client_runtimes})
       when is_list(client_runtimes) and client_runtimes != [] do
    attrs
    |> Map.put_new(
      "data-ash-ui-client-runtimes",
      Jason.encode!(Enum.map(client_runtimes, &EventBinding.serialize_client_runtime/1))
    )
    |> Map.put_new("data-ash-ui-client-hook", "AshUiClient")
  end

  defp merge_client_runtime_mount(attrs, _meta), do: attrs

  defp merge_dom_owner_lowering(attrs, %{dom_owner: dom_owner}) do
    normalized =
      case dom_owner do
        value when is_atom(value) -> Atom.to_string(value)
        value -> value
      end

    attrs =
      if normalized in [nil, ""] do
        attrs
      else
        Map.put_new(attrs, "data-ash-ui-dom-owner", normalized)
      end

    if normalized == "client" do
      Map.put_new(attrs, "data-ash-ui-dom-update", "ignore")
    else
      attrs
    end
  end

  defp merge_dom_owner_lowering(attrs, _meta), do: attrs

  defp merge_navigation_lowering(attrs, %{navigation: navigation}) when is_map(navigation) do
    case Map.get(navigation, :kind) || Map.get(navigation, "kind") do
      kind when kind in [:patch, "patch"] ->
        attrs
        |> Map.put_new("data-ash-ui-link", "patch")
        |> Map.put_new(
          "data-ash-ui-link-state",
          navigation |> navigation_state() |> to_string()
        )

      kind when kind in [:redirect, :navigate, "redirect", "navigate"] ->
        attrs
        |> Map.put_new("data-ash-ui-link", "redirect")
        |> Map.put_new(
          "data-ash-ui-link-state",
          navigation |> navigation_state() |> to_string()
        )

      _other ->
        attrs
    end
  end

  defp merge_navigation_lowering(attrs, _meta), do: attrs

  defp navigation_state(navigation) do
    Map.get(navigation, :state) || Map.get(navigation, "state") || "push"
  end

  defp merge_inferred_navigation_lowering(attrs, tag, meta) when tag in [:a, "a"] do
    href = attr_value(attrs, "href", :href)

    cond do
      has_attr?(attrs, "data-ash-ui-link", :"data-ash-ui-link") ->
        attrs

      has_attr?(attrs, "target", :target) or has_attr?(attrs, "download", :download) ->
        attrs

      has_attr?(attrs, "data-ash-ui-on-click", :"data-ash-ui-on-click") ->
        attrs

      not screen_navigation_href?(href, meta) ->
        attrs

      not generated_screen_navigation_link?(meta) ->
        attrs

      true ->
        kind =
          if route_matches?(href, Map.get(meta, :screen_navigation_patch_routes, [])),
            do: "patch",
            else: "redirect"

        attrs
        |> Map.put_new("data-ash-ui-link", kind)
        |> Map.put_new("data-ash-ui-link-state", "push")
    end
  end

  defp merge_inferred_navigation_lowering(attrs, _tag, _meta), do: attrs

  defp screen_navigation_href?(href, meta) when is_binary(href) do
    String.starts_with?(href, "/") and
      not String.starts_with?(href, "//") and
      route_matches?(href, Map.get(meta, :screen_navigation_routes, []))
  end

  defp screen_navigation_href?(_href, _meta), do: false

  defp route_matches?(href, routes) do
    Enum.any?(routes, &AshUi.Location.same_template?(href, &1))
  end

  defp generated_screen_navigation_link?(%{screen_navigation?: true}), do: true
  defp generated_screen_navigation_link?(%{screen_navigation: true}), do: true
  defp generated_screen_navigation_link?(%{navigation: :screen}), do: true
  defp generated_screen_navigation_link?(%{navigation: %{screen?: true}}), do: true
  defp generated_screen_navigation_link?(%{navigation: %{"screen?" => true}}), do: true
  defp generated_screen_navigation_link?(_meta), do: false

  defp has_attr?(attrs, string_key, atom_key),
    do: Map.has_key?(attrs, string_key) or Map.has_key?(attrs, atom_key)

  defp attr_value(attrs, string_key, atom_key),
    do: Map.get(attrs, string_key) || Map.get(attrs, atom_key)

  defp merge_route_patch_form_lowering(attrs, %{route_patch_form: route_patch_form})
       when is_map(route_patch_form) do
    event =
      route_patch_form
      |> Map.get(:event, Map.get(route_patch_form, "event", "ash_ui:route-params-patch"))
      |> to_string()

    attrs
    |> Map.put_new("data-ash-ui-change", event)
    |> Map.put_new("data-ash-ui-submit", event)
    |> maybe_put_new_attr(
      "data-ash-ui-route-patch-form",
      route_patch_form_name(route_patch_form)
    )
  end

  defp merge_route_patch_form_lowering(attrs, _meta), do: attrs

  defp route_patch_form_name(route_patch_form) do
    Map.get(route_patch_form, :screen) ||
      Map.get(route_patch_form, "screen") ||
      Map.get(route_patch_form, :name) ||
      Map.get(route_patch_form, "name")
  end

  defp maybe_put_new_attr(attrs, _key, value) when value in [nil, ""], do: attrs
  defp maybe_put_new_attr(attrs, key, value), do: Map.put_new(attrs, key, to_string(value))

  defp drop_attr_value?(_attr, nil), do: true

  defp drop_attr_value?(attr, false),
    do: not (aria_attr?(attr) or blueprint_value_attr?(attr))

  defp drop_attr_value?(_attr, _value), do: false

  defp serialize_attr_value(original_attr, value) do
    cond do
      aria_attr?(original_attr) and is_boolean(value) ->
        Atom.to_string(value)

      Blank.blank?(value) ->
        ""

      blueprint_value_attr?(original_attr) ->
        serialize_blueprint_value(value)

      json_attr_value?(original_attr, value) ->
        Jason.encode!(value)

      tuple_attr_value?(original_attr, value) ->
        inspect(value)

      event_atom_attr?(original_attr, value) ->
        kebab_atom(value)

      true ->
        value
    end
  end

  defp aria_attr?(attr), do: attr |> attr_name() |> String.starts_with?("aria-")

  defp serialize_blueprint_value(value) when is_atom(value), do: kebab_atom(value)

  defp serialize_blueprint_value(value) when is_map(value) or is_list(value) or is_tuple(value) do
    value
    |> json_value()
    |> Jason.encode!()
  end

  defp serialize_blueprint_value(value), do: value

  defp json_value(%Decimal{} = value), do: Decimal.to_string(value)

  defp json_value(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> json_value()
  end

  defp json_value({:item, key}), do: %{"item" => json_value(key)}
  defp json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(%{} = value) do
    Map.new(value, fn {key, nested_value} ->
      {json_key(key), json_value(nested_value)}
    end)
  end

  defp json_value(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)

  defp blueprint_value_attr?(attr) when is_binary(attr),
    do: String.starts_with?(attr, "data-ash-ui-value-")

  defp blueprint_value_attr?(_attr), do: false

  defp json_attr_value?(attr, value), do: is_binary(attr) and is_map(value)
  defp tuple_attr_value?(attr, value), do: is_binary(attr) and is_tuple(value)

  defp event_atom_attr?(attr, value) when is_atom(value) do
    attr in ["data-ash-ui-change", "data-ash-ui-submit"] or
      String.starts_with?(attr, "data-ash-ui-on-")
  end

  defp event_atom_attr?(_attr, _value), do: false
end
