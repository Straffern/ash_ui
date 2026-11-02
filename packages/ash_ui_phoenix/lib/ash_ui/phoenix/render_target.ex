defmodule AshUi.Phoenix.RenderTarget do
  @moduledoc false

  use AshUi.RenderTarget

  alias AshUi.RenderTree.{Element, Fragment, Portal, Text}

  @impl AshUi.RenderTarget
  def compiled_table(resource, view) do
    AshUi.Phoenix.PatchArtifact.load(resource, view)
  end

  @doc false
  defdelegate artifact_module(resource), to: AshUi.Phoenix.PatchArtifact

  @impl AshUi.RenderTarget
  def attr_name(key) do
    key = to_string(key)

    cond do
      key == "data-ash-ui-binding" ->
        "phx-value-binding"

      key == "data-ash-ui-key" ->
        "phx-key"

      key == "data-ash-ui-client-hook" ->
        "phx-hook"

      key == "data-ash-ui-dom-update" ->
        "phx-update"

      key == "data-ash-ui-link" ->
        "data-phx-link"

      key == "data-ash-ui-link-state" ->
        "data-phx-link-state"

      key == "data-ash-ui-change" ->
        "phx-change"

      key == "data-ash-ui-submit" ->
        "phx-submit"

      key == "data-ash-ui-debounce" ->
        "phx-debounce"

      key == "data-ash-ui-throttle" ->
        "phx-throttle"

      key == "data-ash-ui-on-input" ->
        "phx-change"

      String.starts_with?(key, "data-ash-ui-on-") ->
        "phx-" <> String.replace_prefix(key, "data-ash-ui-on-", "")

      String.starts_with?(key, "data-ash-ui-value-") ->
        "phx-value-" <> String.replace_prefix(key, "data-ash-ui-value-", "")

      true ->
        key
    end
  end

  @impl AshUi.RenderTarget
  def finalize_tree(nil), do: nil
  def finalize_tree(tree), do: put_ids(tree, [])

  @impl AshUi.RenderTarget
  def finalize_skeleton_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn {key, _value}, kept ->
      case to_string(key) do
        "id" -> Map.put(kept, key, "")
        name when name in ["data-ash-ui-client-hook", "phx-hook"] -> Map.put(kept, key, true)
        name when name in ["data-ash-ui-dom-update", "phx-update"] -> Map.put(kept, key, true)
        _other -> kept
      end
    end)
  end

  # The native LiveView event attribute already carries the complete binding
  # key (`ash_ui:dispatch:<key>`). For the overwhelmingly common
  # one-event element, repeating that key in both neutral lookup attributes
  # only inflates every rendered row. Multi-event elements retain the lookup
  # attributes because an unqualified component event would otherwise be
  # ambiguous.
  @impl AshUi.RenderTarget
  def finalize_attrs(attrs, _tag, _meta, [%AshUi.EventBinding{dom_event: dom_event}]) do
    event = dom_event |> to_string() |> String.replace("_", "-")

    attrs
    |> Map.delete("data-ash-ui-binding")
    |> Map.delete("data-ash-ui-binding-#{event}")
  end

  def finalize_attrs(attrs, _tag, _meta, _events), do: attrs

  defp put_ids(%Element{} = element, path) do
    path = path ++ [node_path_component(element)]
    meta = element.meta || %{}

    identity =
      case Map.get(meta, :__bp_addr__) do
        address when is_binary(address) ->
          {address, Map.get(meta, :__bp_runtime_chain__, [])}

        _unstamped ->
          path
      end

    attrs =
      if id_required?(element) and not authored_id?(element.attrs) do
        Map.put(element.attrs, "id", stable_dom_id(identity))
      else
        element.attrs
      end

    %Element{element | attrs: attrs, children: put_child_ids(element.children, path)}
  end

  defp put_ids(%Fragment{} = fragment, path) do
    path = path ++ [node_path_component(fragment)]
    %Fragment{fragment | children: put_child_ids(fragment.children, path)}
  end

  defp put_ids(%Portal{} = portal, path) do
    path = path ++ [node_path_component(portal)]
    %Portal{portal | children: put_child_ids(portal.children, path)}
  end

  defp put_ids(%Text{} = text, _path), do: text

  defp put_child_ids(children, path) when is_list(children) do
    duplicate_counts = Enum.frequencies_by(children, &node_path_component/1)

    children
    |> Enum.map_reduce(%{}, fn child, seen ->
      component = node_path_component(child)
      count = Map.get(duplicate_counts, component, 0)
      ordinal = Map.get(seen, component, 0)
      seen = Map.put(seen, component, ordinal + 1)

      child_path =
        if count > 1 and unkeyed_node?(child) do
          path ++ [{:sibling, component, ordinal}]
        else
          path
        end

      {put_ids(child, child_path), seen}
    end)
    |> elem(0)
  end

  defp node_path_component(%Element{key: key}) when not is_nil(key), do: {:key, key}

  defp node_path_component(%Element{tag: tag, meta: meta}) do
    {:element, tag,
     Map.take(meta || %{}, [
       :component,
       :component_part,
       :semantic,
       :node
     ])}
  end

  defp node_path_component(%Fragment{key: key}) when not is_nil(key), do: {:key, key}
  defp node_path_component(%Fragment{}), do: :fragment
  defp node_path_component(%Portal{key: key}) when not is_nil(key), do: {:key, key}
  defp node_path_component(%Portal{target: target}), do: {:portal, target}
  defp node_path_component(%Text{key: key}) when not is_nil(key), do: {:key, key}
  defp node_path_component(%Text{}), do: :text
  defp node_path_component(other), do: {:other, inspect(other)}

  defp unkeyed_node?(%Element{key: nil}), do: true
  defp unkeyed_node?(%Fragment{key: nil}), do: true
  defp unkeyed_node?(%Portal{key: nil}), do: true
  defp unkeyed_node?(%Text{key: nil}), do: true
  defp unkeyed_node?(_node), do: false

  defp authored_id?(attrs) when is_map(attrs) do
    Map.has_key?(attrs, "id") or Map.has_key?(attrs, :id)
  end

  defp id_required?(%Element{attrs: attrs, meta: meta}) do
    client_hook_attr?(attrs) or update_attr?(attrs) or client_mount_meta?(meta) or
      client_dom_owner?(meta)
  end

  defp client_hook_attr?(attrs) when is_map(attrs) do
    has_attr?(attrs, "data-ash-ui-client-hook", :"data-ash-ui-client-hook") or
      has_attr?(attrs, "phx-hook", :"phx-hook")
  end

  defp update_attr?(attrs) when is_map(attrs) do
    has_attr?(attrs, "data-ash-ui-dom-update", :"data-ash-ui-dom-update") or
      has_attr?(attrs, "phx-update", :"phx-update")
  end

  defp client_mount_meta?(meta) when is_map(meta) do
    present_list?(Map.get(meta, :client_actions)) or
      present_list?(Map.get(meta, :client_runtimes))
  end

  defp client_mount_meta?(_meta), do: false

  defp client_dom_owner?(meta) when is_map(meta) do
    case Map.get(meta, :dom_owner) do
      value when value in [:client, "client"] -> true
      _other -> false
    end
  end

  defp client_dom_owner?(_meta), do: false

  defp present_list?(value), do: is_list(value) and value != []

  defp has_attr?(attrs, string_key, atom_key),
    do: Map.has_key?(attrs, string_key) or Map.has_key?(attrs, atom_key)

  defp stable_dom_id(path) do
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary(path))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "bp-" <> hash
  end
end
