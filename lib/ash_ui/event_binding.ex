defmodule AshUi.EventBinding do
  @moduledoc false

  @opaque t :: %__MODULE__{
            dom_event: atom() | String.t(),
            ui_event: atom() | String.t(),
            args_exprs: map(),
            meta: map()
          }

  @client_action_reserved_opts [:target, :using, :dom_event]
  @client_runtime_reserved_opts [:target]
  @modifier_fields [:alt, :ctrl, :meta, :shift]
  @payload_schemas %{
    click: [:button, :buttons | @modifier_fields],
    keydown: [:key | @modifier_fields],
    keyup: [:key | @modifier_fields],
    input: [:value],
    change: [:form, :value, :checked, :selected_options],
    submit: [:form],
    reorder: [:order],
    contextmenu: [
      :button,
      :buttons,
      :client_x,
      :client_y,
      :page_x,
      :page_y,
      :screen_x,
      :screen_y | @modifier_fields
    ]
  }

  defstruct [:dom_event, :ui_event, args_exprs: %{}, meta: %{}]

  def new(dom_event, ui_event, opts \\ []) when is_list(opts) do
    %__MODULE__{
      dom_event: normalize_dom_event(dom_event),
      ui_event: normalize_ui_event(ui_event),
      args_exprs: Map.new(Keyword.get(opts, :args_exprs, %{})),
      meta: Map.new(Keyword.get(opts, :meta, %{}))
    }
  end

  def payload_schema(dom_event) do
    Map.get(@payload_schemas, base_dom_event(dom_event), [])
  end

  def payload_field?(dom_event, field) do
    normalized = normalize_payload_field(field)
    normalized in payload_schema(dom_event)
  end

  def payload_fields(term), do: collect_payload_fields(term, [])

  def value_source_for(tag, attrs, dom_event) do
    cond do
      base_dom_event(dom_event) not in [:input, :change] ->
        nil

      input_type(attrs) == "checkbox" ->
        :checked

      tag in [:select, "select"] and multiple_select?(attrs) ->
        :selected_options

      tag in [:input, "input", :textarea, "textarea", :select, "select"] ->
        :value

      true ->
        nil
    end
  end

  def binding_key(path, %__MODULE__{} = binding) when is_list(path) do
    binding_key(path, binding.dom_event)
  end

  def binding_key(path, dom_event) when is_list(path) do
    path_components =
      path
      |> Enum.map(&binding_key_path_component/1)
      |> Enum.reject(&(&1 in [nil, ""]))

    (path_components ++ [dom_event_key_component(dom_event)])
    |> Enum.join(".")
  end

  defp binding_key_path_component({:key, key}), do: key_component(key)
  defp binding_key_path_component({:index, index}) when is_integer(index), do: "i#{index}"
  defp binding_key_path_component(index) when is_integer(index), do: "i#{index}"
  defp binding_key_path_component(segment), do: key_component(segment)

  @doc "Key-safe serialization of a dom event, as used inside binding keys."
  def event_key_component(dom_event), do: dom_event_key_component(dom_event)

  defp dom_event_key_component(dom_event) when is_atom(dom_event) do
    dom_event
    |> Atom.to_string()
    |> String.replace("_", "-")
    |> safe_event_component()
  end

  defp dom_event_key_component("data-ash-ui-on-" <> event), do: safe_event_component(event)
  defp dom_event_key_component(dom_event), do: safe_event_component(to_string(dom_event))

  @doc """
  Injective, key-safe serialization of an item/path identity component.

  Nothing decodes these — resolution re-encodes candidate keys and compares
  — so the only contract is injectivity and determinism. The common key
  shapes get compact encodings (a UUID key is 23 chars instead of the
  57-char ETF envelope); binding keys are emitted once per bound element per
  keyed row, so this is initial-render byte mass at scale.
  """
  def key_component(value) when is_binary(value) do
    case uuid_bytes(value) do
      {:ok, bytes} -> "u" <> Base.url_encode64(bytes, padding: false)
      :error -> "s" <> Base.url_encode64(value, padding: false)
    end
  end

  def key_component(value) when is_integer(value) and value >= 0, do: "n#{value}"

  def key_component(value) do
    "k" <> Base.url_encode64(:erlang.term_to_binary(value), padding: false)
  end

  defp uuid_bytes(
         <<a::binary-8, ?-, b::binary-4, ?-, c::binary-4, ?-, d::binary-4, ?-, e::binary-12>>
       ) do
    # :binary.decode_hex is a mixed-case BIF — this runs once per keyed-row
    # binding component, so the decode is initial-render CPU at scale.
    {:ok, :binary.decode_hex(<<a::binary, b::binary, c::binary, d::binary, e::binary>>)}
  rescue
    ArgumentError -> :error
  end

  defp uuid_bytes(_other), do: :error

  defp safe_event_component(value) do
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, value) do
      value
    else
      "e" <> Base.url_encode64(value, padding: false)
    end
  end

  def runtime_event(binding, params \\ %{})

  def runtime_event(%__MODULE__{meta: %{key_filter: key_filter} = meta} = binding, params)
      when not is_nil(key_filter) do
    if key_filter_matches?(key_filter, params) do
      runtime_event(%{binding | meta: Map.delete(meta, :key_filter)}, params)
    else
      :ignore
    end
  end

  def runtime_event(%__MODULE__{} = binding, params) do
    {:dispatch, [], normalize_ui_event(binding.ui_event), event_payload(binding, params)}
  end

  def client_action(action, opts \\ []) when is_list(opts) do
    target =
      case Keyword.fetch(opts, :target) do
        {:ok, value} -> value
        :error -> raise ArgumentError, "client action #{inspect(action)} requires :target"
      end

    %{
      action: action,
      target: target,
      using: Keyword.get(opts, :using),
      dom_event: Keyword.get(opts, :dom_event),
      opts: opts |> Keyword.drop(@client_action_reserved_opts) |> Map.new()
    }
  end

  def client_runtime(runtime, opts \\ []) when is_list(opts) do
    target =
      case Keyword.fetch(opts, :target) do
        {:ok, value} -> value
        :error -> raise ArgumentError, "client runtime #{inspect(runtime)} requires :target"
      end

    %{
      runtime: runtime,
      target: target,
      opts: opts |> Keyword.drop(@client_runtime_reserved_opts) |> Map.new()
    }
  end

  def client_action?(%{action: _action, target: _target}), do: true
  def client_action?(_value), do: false

  def client_runtime?(%{runtime: _runtime, target: _target}), do: true
  def client_runtime?(_value), do: false

  def client_target(%{target: target}), do: target
  def client_target(_value), do: nil

  def reorder_client_entities(nil), do: {[], []}
  def reorder_client_entities(false), do: {[], []}

  def reorder_client_entities(reorder) when is_list(reorder) or is_map(reorder) do
    opts = reorder_opts(reorder)

    case Keyword.fetch(opts, :action) do
      {:ok, action} when is_atom(action) ->
        target =
          Keyword.get(opts, :target) ||
            raise ArgumentError, "reorder metadata for #{inspect(action)} requires :target"

        action_opts =
          opts
          |> Keyword.drop([:action, :runtime])
          |> Keyword.put(:target, target)
          |> Keyword.put_new(:using, :reorder_list)

        runtime =
          case Keyword.get(opts, :runtime, :track_sort) do
            nil -> []
            runtime_name -> [client_runtime(runtime_name, target: target)]
          end

        {[client_action(action, action_opts)], runtime}

      {:ok, other} ->
        raise ArgumentError, "reorder :action must be an atom, got: #{inspect(other)}"

      :error ->
        {[], []}
    end
  end

  def reorder_client_entities(other) do
    raise ArgumentError, "reorder metadata expects a keyword list or map, got: #{inspect(other)}"
  end

  def merge_reorder_client_entities(client_actions, client_runtimes, meta) when is_map(meta) do
    {reorder_actions, reorder_runtimes} = reorder_client_entities(Map.get(meta, :reorder))

    {
      List.wrap(client_actions) ++
        List.wrap(Map.get(meta, :client_actions, [])) ++ reorder_actions,
      List.wrap(client_runtimes) ++
        List.wrap(Map.get(meta, :client_runtimes, [])) ++ reorder_runtimes
    }
  end

  def merge_reorder_client_entities(client_actions, client_runtimes, _meta) do
    {List.wrap(client_actions), List.wrap(client_runtimes)}
  end

  def put_client_dom_event(%{} = action, dom_event), do: Map.put(action, :dom_event, dom_event)

  defp reorder_opts(%{} = reorder), do: Map.to_list(reorder)
  defp reorder_opts(reorder) when is_list(reorder), do: reorder

  def infer_dom_event(nil), do: nil
  def infer_dom_event(tag) when tag in [:form, "form"], do: :submit

  def infer_dom_event(tag)
      when tag in [:input, "input", :textarea, "textarea", :select, "select"] do
    :input
  end

  def infer_dom_event(tag) when tag in [:button, "button", :a, "a"], do: :click
  def infer_dom_event(_tag), do: nil

  def serialize_client_action(%{} = action) do
    %{
      "action" => ui_event_param(Map.fetch!(action, :action)),
      "target" => to_string(Map.fetch!(action, :target)),
      "using" => serialize_optional(Map.get(action, :using)),
      "dom_event" => serialize_optional(Map.get(action, :dom_event)),
      "opts" => serialize_opts(Map.get(action, :opts, %{}))
    }
  end

  def serialize_client_runtime(%{} = runtime) do
    %{
      "runtime" => serialize_optional(Map.fetch!(runtime, :runtime)),
      "target" => to_string(Map.fetch!(runtime, :target)),
      "opts" => serialize_opts(Map.get(runtime, :opts, %{}))
    }
  end

  def client_dispatch_params(%{} = action, args \\ %{}) when is_map(args) do
    %{"action" => ui_event_param(Map.fetch!(action, :action))}
    |> Map.merge(stringify_keys(args))
  end

  def from_dom_attr(attr, value) do
    new(attr_to_dom_event(attr), value)
  end

  def dom_attr(%__MODULE__{dom_event: dom_event}), do: dom_attr(dom_event)

  def dom_attr(dom_event) when is_atom(dom_event) do
    "data-ash-ui-on-" <> (dom_event |> Atom.to_string() |> String.replace("_", "-"))
  end

  def dom_attr("data-ash-ui-on-" <> _ = dom_event), do: dom_event
  def dom_attr(dom_event) when is_binary(dom_event), do: dom_event

  def ui_event_param(%__MODULE__{ui_event: ui_event}), do: ui_event_param(ui_event)

  def ui_event_param(ui_event) when is_atom(ui_event) do
    ui_event
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  def ui_event_param(ui_event) when is_binary(ui_event), do: ui_event

  defp serialize_optional(nil), do: nil
  defp serialize_optional(value) when is_atom(value), do: Atom.to_string(value)
  defp serialize_optional(value), do: value

  defp event_payload(%__MODULE__{} = binding, params) do
    params = normalize_payload_map(params)

    binding_args =
      binding.args_exprs
      |> normalize_payload_map()
      |> Enum.map(fn {key, value} -> {key, resolve_binding_arg(value, params)} end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    binding_args
    |> Map.merge(params)
    |> maybe_put_provided_value(binding)
    |> maybe_put_bound_field(binding)
  end

  defp maybe_put_bound_field(payload, %__MODULE__{meta: %{bound_field: field}})
       when is_atom(field) do
    cond do
      Map.has_key?(payload, field) ->
        payload

      Map.has_key?(payload, Atom.to_string(field)) ->
        Map.put(payload, field, Map.get(payload, Atom.to_string(field)))

      Map.has_key?(payload, :value) ->
        Map.put(payload, field, Map.get(payload, :value))

      Map.has_key?(payload, "value") ->
        Map.put(payload, field, Map.get(payload, "value"))

      true ->
        payload
    end
  end

  defp maybe_put_bound_field(payload, _binding), do: payload

  defp maybe_put_provided_value(payload, %__MODULE__{meta: %{provides_value?: true} = meta}) do
    if present_payload_value?(payload) do
      payload
    else
      case provided_payload_value(payload, Map.get(meta, :value_source, :value)) do
        nil -> payload
        value -> put_provided_value(payload, value)
      end
    end
  end

  defp maybe_put_provided_value(payload, _binding), do: payload

  defp put_provided_value(payload, value) when is_map(payload) do
    payload
    |> Map.put("value", value)
    |> then(fn payload ->
      if Map.has_key?(payload, :value), do: Map.put(payload, :value, value), else: payload
    end)
  end

  defp present_payload_value?(payload) when is_map(payload) do
    (Map.has_key?(payload, :value) and not is_nil(Map.get(payload, :value))) or
      (Map.has_key?(payload, "value") and not is_nil(Map.get(payload, "value")))
  end

  defp present_payload_value?(_payload), do: false

  defp provided_payload_value(payload, :checked), do: payload_value(payload, :checked)

  defp provided_payload_value(payload, :selected_options) do
    payload_value(payload, :selectedOptions) ||
      payload_value(payload, :selected_options) ||
      payload_value(payload, :value)
  end

  defp provided_payload_value(payload, _source), do: target_payload_value(payload)

  defp target_payload_value(payload) when is_map(payload) do
    target = Map.get(payload, "_target") || Map.get(payload, :_target)

    case target do
      [_root | _rest] = path -> value_at_payload_path(payload, path)
      _other -> nil
    end
  end

  defp value_at_payload_path(payload, [segment | rest]) when is_map(payload) do
    payload
    |> fetch_payload_key(segment)
    |> value_at_payload_path(rest)
  end

  defp value_at_payload_path(value, []), do: value

  defp value_at_payload_path(_payload, _path), do: nil

  defp fetch_payload_key(payload, key) when is_map(payload) do
    cond do
      Map.has_key?(payload, key) ->
        Map.get(payload, key)

      is_atom(key) and Map.has_key?(payload, Atom.to_string(key)) ->
        Map.get(payload, Atom.to_string(key))

      is_binary(key) ->
        case safe_string_to_atom(key) do
          nil -> nil
          atom -> Map.get(payload, atom)
        end

      true ->
        nil
    end
  end

  defp resolve_binding_arg({:event, field}, params) do
    payload_value(params, normalize_payload_field(field))
  end

  defp resolve_binding_arg(%Ash.Query.Call{name: :event, args: [field]}, params) do
    payload_value(params, normalize_payload_field(field))
  end

  defp resolve_binding_arg(%AshUi.Expr.Compiled{ir: ir}, params) do
    resolve_binding_arg(ir, params)
  end

  defp resolve_binding_arg(%_{} = struct, _params), do: struct

  defp resolve_binding_arg(%{} = map, params) do
    Map.new(map, fn {key, value} -> {key, resolve_binding_arg(value, params)} end)
  end

  defp resolve_binding_arg(list, params) when is_list(list) do
    Enum.map(list, &resolve_binding_arg(&1, params))
  end

  defp resolve_binding_arg(value, _params), do: value

  defp collect_payload_fields({:event, field}, acc), do: [field | acc]

  defp collect_payload_fields(%Ash.Query.Call{name: :event, args: [field]}, acc),
    do: [field | acc]

  defp collect_payload_fields(%AshUi.Expr.Compiled{ir: ir}, acc) do
    collect_payload_fields(ir, acc)
  end

  defp collect_payload_fields(%_struct{}, acc), do: acc

  defp collect_payload_fields(%{} = map, acc) do
    Enum.reduce(map, acc, fn {key, value}, next ->
      next
      |> then(&collect_payload_fields(key, &1))
      |> then(&collect_payload_fields(value, &1))
    end)
  end

  defp collect_payload_fields(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_payload_fields/2)
  end

  defp collect_payload_fields(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, &collect_payload_fields/2)
  end

  defp collect_payload_fields(_term, acc), do: acc

  defp serialize_opts(opts) when opts in [%{}, []], do: %{}

  defp serialize_opts(opts) when is_map(opts) do
    Enum.into(opts, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(args) do
    Enum.into(args, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp key_filter_matches?(filters, params) when is_list(filters) do
    Enum.any?(filters, &key_filter_matches?(&1, params))
  end

  defp key_filter_matches?(%{key: key, modifiers: modifiers}, params) do
    payload = normalize_payload_map(params)

    payload_key(payload) == dom_key_name(key) and
      modifiers_match?(List.wrap(modifiers), payload)
  end

  defp key_filter_matches?(_filter, _params), do: true

  defp payload_key(payload) do
    payload_value(payload, :key)
    |> case do
      nil -> nil
      key -> to_string(key)
    end
  end

  defp modifiers_match?(modifiers, payload) do
    expected =
      modifiers
      |> Enum.map(&normalize_modifier/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.all?([:alt, :ctrl, :meta, :shift], fn modifier ->
      modifier_pressed?(payload, modifier) == MapSet.member?(expected, modifier)
    end)
  end

  defp modifier_pressed?(payload, modifier) do
    modifier
    |> modifier_payload_keys()
    |> Enum.find_value(false, fn key ->
      case payload_value(payload, key) do
        nil -> nil
        value -> truthy_modifier?(value)
      end
    end)
  end

  defp modifier_payload_keys(:alt), do: [:altKey, :alt_key, :alt]
  defp modifier_payload_keys(:ctrl), do: [:ctrlKey, :ctrl_key, :ctrl, :control]
  defp modifier_payload_keys(:meta), do: [:metaKey, :meta_key, :meta]
  defp modifier_payload_keys(:shift), do: [:shiftKey, :shift_key, :shift]
  defp modifier_payload_keys(other), do: [other]

  defp payload_value(payload, key) when is_map(payload) and is_atom(key) do
    string_key = Atom.to_string(key)
    camel_key = camelize_payload_key(string_key)

    cond do
      Map.has_key?(payload, key) -> Map.get(payload, key)
      Map.has_key?(payload, string_key) -> Map.get(payload, string_key)
      Map.has_key?(payload, camel_key) -> Map.get(payload, camel_key)
      true -> nil
    end
  end

  defp normalize_modifier(:alt), do: :alt
  defp normalize_modifier(:ctrl), do: :ctrl
  defp normalize_modifier(:control), do: :ctrl
  defp normalize_modifier(:meta), do: :meta
  defp normalize_modifier(:shift), do: :shift
  defp normalize_modifier("alt"), do: :alt
  defp normalize_modifier("ctrl"), do: :ctrl
  defp normalize_modifier("control"), do: :ctrl
  defp normalize_modifier("meta"), do: :meta
  defp normalize_modifier("shift"), do: :shift
  defp normalize_modifier(_modifier), do: nil

  defp truthy_modifier?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy_modifier?(_value), do: false

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

  defp base_dom_event(dom_event) when is_atom(dom_event) do
    dom_event
    |> Atom.to_string()
    |> base_dom_event_string()
    |> String.to_atom()
  end

  defp base_dom_event("data-ash-ui-on-" <> event), do: base_dom_event(event)

  defp base_dom_event(dom_event) when is_binary(dom_event) do
    dom_event
    |> String.replace("-", "_")
    |> base_dom_event_string()
    |> String.to_atom()
  end

  defp base_dom_event_string("window_" <> event), do: event
  defp base_dom_event_string(event), do: event

  defp normalize_payload_field(field) when field in [:selectedOptions, "selectedOptions"],
    do: :selected_options

  defp normalize_payload_field(field) when field in [:clientX, "clientX"], do: :client_x
  defp normalize_payload_field(field) when field in [:clientY, "clientY"], do: :client_y
  defp normalize_payload_field(field) when field in [:pageX, "pageX"], do: :page_x
  defp normalize_payload_field(field) when field in [:pageY, "pageY"], do: :page_y
  defp normalize_payload_field(field) when field in [:screenX, "screenX"], do: :screen_x
  defp normalize_payload_field(field) when field in [:screenY, "screenY"], do: :screen_y
  defp normalize_payload_field(field) when is_atom(field), do: field

  defp normalize_payload_field(field) when is_binary(field) do
    field
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> String.to_atom(field)
  end

  defp input_type(attrs) when is_map(attrs) do
    attrs
    |> Map.get("type", Map.get(attrs, :type))
    |> case do
      nil -> nil
      value -> value |> to_string() |> String.downcase()
    end
  end

  defp multiple_select?(attrs) when is_map(attrs) do
    Map.get(attrs, "multiple", Map.get(attrs, :multiple)) in [true, "true", ""]
  end

  defp camelize_payload_key("selected_options"), do: "selectedOptions"
  defp camelize_payload_key("alt"), do: "altKey"
  defp camelize_payload_key("ctrl"), do: "ctrlKey"
  defp camelize_payload_key("meta"), do: "metaKey"
  defp camelize_payload_key("shift"), do: "shiftKey"
  defp camelize_payload_key("client_x"), do: "clientX"
  defp camelize_payload_key("client_y"), do: "clientY"
  defp camelize_payload_key("page_x"), do: "pageX"
  defp camelize_payload_key("page_y"), do: "pageY"
  defp camelize_payload_key("screen_x"), do: "screenX"
  defp camelize_payload_key("screen_y"), do: "screenY"
  defp camelize_payload_key(key), do: key

  defp normalize_dom_event(dom_event) when is_atom(dom_event), do: dom_event

  defp normalize_dom_event(dom_event) when is_binary(dom_event) do
    case dom_event do
      "data-ash-ui-on-" <> event -> blueprint_dom_event(event)
      other -> other
    end
  end

  defp normalize_ui_event(ui_event) when is_atom(ui_event), do: ui_event

  defp normalize_ui_event(ui_event) when is_binary(ui_event) do
    normalized = String.replace(ui_event, "-", "_")

    try do
      String.to_existing_atom(normalized)
    rescue
      ArgumentError -> ui_event
    end
  end

  defp attr_to_dom_event("data-ash-ui-on-" <> event), do: blueprint_dom_event(event)
  defp attr_to_dom_event(attr), do: attr

  defp blueprint_dom_event(event) do
    normalized = String.replace(event, "-", "_")

    try do
      String.to_existing_atom(normalized)
    rescue
      ArgumentError -> event
    end
  end

  defp normalize_payload_map(value) when is_map(value), do: Map.new(value)
  defp normalize_payload_map(value) when is_list(value), do: Map.new(value)
  defp normalize_payload_map(_value), do: %{}

  defp safe_string_to_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end
end
