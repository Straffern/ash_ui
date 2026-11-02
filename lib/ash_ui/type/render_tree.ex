defmodule AshUi.Type.RenderTree do
  @moduledoc """
  Ash type for authored AshUi render-tree values.

  This type owns value-shape validation only. It accepts already-built
  `AshUi.RenderTree` structs and the canonical map nodes produced by
  the current constructor pipeline, but deliberately leaves existence checks
  such as component resolution and action/resource validation to verifiers.
  """

  use Ash.Type

  alias AshUi.EventBinding
  alias AshUi.RenderTree
  alias AshUi.SafeHTML

  @map_node_kinds [
    :attached_view,
    :component,
    :each,
    :element,
    :fragment,
    :if,
    :stack,
    :row,
    :text,
    :when
  ]

  @impl true
  def storage_type(_constraints), do: :map

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, _constraints) do
    if render_tree_value?(value), do: {:ok, value}, else: :error
  end

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints), do: {:ok, value}

  @impl true
  def apply_constraints(nil, _constraints), do: {:ok, nil}

  def apply_constraints(value, _constraints) do
    case validate_node(value, []) do
      :ok ->
        {:ok, value}

      {:error, path, message} ->
        {:error, [message: "invalid render tree at #{format_path(path)}: #{message}"]}
    end
  end

  defp render_tree_value?(%RenderTree.Element{}), do: true
  defp render_tree_value?(%RenderTree.Text{}), do: true
  defp render_tree_value?(%RenderTree.Fragment{}), do: true
  defp render_tree_value?(%RenderTree.Portal{}), do: true
  defp render_tree_value?(%{kind: kind}) when kind in @map_node_kinds, do: true
  defp render_tree_value?(nodes) when is_list(nodes), do: true
  defp render_tree_value?(_other), do: false

  defp validate_node(nil, _path), do: :ok

  defp validate_node(%RenderTree.Element{} = node, path) do
    with :ok <- validate_element_tag(node.tag, path),
         :ok <- validate_map(node.attrs, path ++ [:attrs], "attrs must be a map"),
         :ok <- validate_presentation_attrs(node.attrs, node.meta, path ++ [:attrs]),
         :ok <- validate_list(node.children, path ++ [:children], "children must be a list"),
         :ok <- validate_event_bindings(node.event_bindings, path ++ [:event_bindings]),
         :ok <- validate_map(node.meta, path ++ [:meta], "meta must be a map") do
      validate_children(node.children, path ++ [:children])
    end
  end

  defp validate_node(%RenderTree.Text{} = node, path) do
    validate_text_content(node.content, path ++ [:content])
  end

  defp validate_node(%RenderTree.Fragment{} = node, path) do
    with :ok <- validate_list(node.children, path ++ [:children], "children must be a list") do
      validate_children(node.children, path ++ [:children])
    end
  end

  defp validate_node(%RenderTree.Portal{} = node, path) do
    with :ok <- validate_list(node.children, path ++ [:children], "children must be a list") do
      validate_children(node.children, path ++ [:children])
    end
  end

  defp validate_node(nodes, path) when is_list(nodes), do: validate_children(nodes, path)

  defp validate_node(%{kind: :text} = node, path) do
    with :ok <- required_key(node, :content, path) do
      validate_text_content(Map.get(node, :content), path ++ [:content])
    end
  end

  defp validate_node(%{kind: :fragment} = node, path) do
    validate_map_children(node, path)
  end

  defp validate_node(%{kind: kind} = node, path) when kind in [:stack, :row] do
    with :ok <- validate_map_children(node, path),
         :ok <-
           validate_map(Map.get(node, :options, %{}), path ++ [:options], "options must be a map") do
      :ok
    end
  end

  defp validate_node(%{kind: :element} = node, path) do
    with :ok <- required_key(node, :tag, path),
         :ok <- validate_element_tag(Map.get(node, :tag), path ++ [:tag]),
         :ok <- validate_map(Map.get(node, :attrs, %{}), path ++ [:attrs], "attrs must be a map"),
         :ok <-
           validate_presentation_attrs(
             Map.get(node, :attrs, %{}),
             Map.get(node, :meta, %{}),
             path ++ [:attrs]
           ),
         :ok <-
           validate_list(Map.get(node, :events, []), path ++ [:events], "events must be a list"),
         :ok <-
           validate_list(Map.get(node, :states, []), path ++ [:states], "states must be a list"),
         :ok <- validate_map(Map.get(node, :meta, %{}), path ++ [:meta], "meta must be a map"),
         :ok <- validate_part(Map.get(node, :part), path ++ [:part]),
         :ok <- validate_map_children(node, path) do
      :ok
    end
  end

  defp validate_node(%{kind: :component} = node, path) do
    with :ok <- required_key(node, :component, path),
         :ok <- required_key(node, :view, path) do
      validate_node(Map.get(node, :view), path ++ [:view])
    end
  end

  defp validate_node(%{kind: :when} = node, path) do
    with :ok <- required_key(node, :child, path) do
      validate_node(Map.get(node, :child), path ++ [:child])
    end
  end

  defp validate_node(%{kind: :if} = node, path) do
    with :ok <- required_key(node, :then, path),
         :ok <- validate_node(Map.get(node, :then), path ++ [:then]) do
      case Map.fetch(node, :else) do
        {:ok, child} -> validate_node(child, path ++ [:else])
        :error -> :ok
      end
    end
  end

  defp validate_node(%{kind: :each} = node, path) do
    with :ok <- required_key(node, :items, path),
         :ok <- required_key(node, :as, path),
         :ok <- required_key(node, :child, path),
         :ok <- validate_atom(Map.get(node, :as), path ++ [:as], ":as must be an atom") do
      validate_node(Map.get(node, :child), path ++ [:child])
    end
  end

  defp validate_node(%{kind: :attached_view} = node, path) do
    with :ok <- required_key(node, :child, path) do
      validate_node(Map.get(node, :child), path ++ [:child])
    end
  end

  defp validate_node(%{kind: kind}, path),
    do: {:error, path, "unknown node kind #{inspect(kind)}"}

  defp validate_node(other, path), do: {:error, path, "unsupported node #{inspect(other)}"}

  defp validate_map_children(node, path) do
    with :ok <-
           validate_list(
             Map.get(node, :children, []),
             path ++ [:children],
             "children must be a list"
           ) do
      validate_children(Map.get(node, :children, []), path ++ [:children])
    end
  end

  defp validate_children(children, path) do
    children
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {child, index}, :ok ->
      case validate_node(child, path ++ [index]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_element_tag(nil, _path), do: :ok
  defp validate_element_tag(tag, _path) when is_atom(tag) or is_binary(tag), do: :ok
  defp validate_element_tag(_tag, path), do: {:error, path, "tag must be an atom, string, or nil"}

  defp validate_part(nil, _path), do: :ok
  defp validate_part(part, _path) when is_atom(part) or is_binary(part), do: :ok
  defp validate_part(_part, path), do: {:error, path, "part must be an atom, string, or nil"}

  defp validate_text_content({:safe, iodata}, path), do: validate_iodata(iodata, path)
  defp validate_text_content(%SafeHTML{}, _path), do: :ok
  defp validate_text_content(nil, _path), do: :ok

  defp validate_text_content(value, _path)
       when is_binary(value) or is_atom(value) or is_number(value) or is_boolean(value),
       do: :ok

  defp validate_text_content(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case validate_text_content(value, path ++ [index]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_text_content(_value, path) do
    {:error, path,
     "text content must be nil, a scalar, SafeHTML, {:safe, iodata}, or a list of text content"}
  end

  defp validate_iodata(binary, _path) when is_binary(binary), do: :ok
  defp validate_iodata(byte, _path) when is_integer(byte) and byte >= 0 and byte <= 255, do: :ok

  defp validate_iodata(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case validate_iodata(value, path ++ [index]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_iodata(_value, path), do: {:error, path, "safe text content must be iodata"}

  defp validate_map(value, _path, _message) when is_map(value), do: :ok
  defp validate_map(_value, path, message), do: {:error, path, message}

  defp validate_presentation_attrs(attrs, meta, path) do
    generated_icon_class? =
      is_map(meta) and Map.get(meta, :generated_class) == :typed_icon_name

    case Enum.find(Map.keys(attrs), fn key ->
           key = if is_atom(key), do: Atom.to_string(key), else: key
           key == "style" or (key == "class" and not generated_icon_class?)
         end) do
      nil ->
        :ok

      _class_or_style ->
        {:error, path,
         "class and style attributes are forbidden in RenderTree values; " <>
           "paint with part and state attributes"}
    end
  end

  defp validate_list(value, _path, _message) when is_list(value), do: :ok
  defp validate_list(_value, path, message), do: {:error, path, message}

  defp validate_atom(value, _path, _message) when is_atom(value), do: :ok
  defp validate_atom(_value, path, message), do: {:error, path, message}

  defp validate_event_bindings(bindings, path) when is_list(bindings) do
    Enum.reduce_while(bindings, :ok, fn
      %EventBinding{}, :ok ->
        {:cont, :ok}

      other, :ok ->
        {:halt,
         {:error, path, "event binding must be #{inspect(EventBinding)}, got #{inspect(other)}"}}
    end)
  end

  defp validate_event_bindings(_bindings, path),
    do: {:error, path, "event_bindings must be a list"}

  defp required_key(node, key, path) do
    if Map.has_key?(node, key),
      do: :ok,
      else: {:error, path, "missing required key #{inspect(key)}"}
  end

  defp format_path([]), do: "$"

  defp format_path(path) do
    Enum.reduce(path, "$", fn
      index, acc when is_integer(index) -> acc <> "[#{index}]"
      key, acc -> acc <> "." <> to_string(key)
    end)
  end
end
