defmodule AshUi.AttrMerge do
  @moduledoc false

  @spec merge_tree_attrs(map() | keyword() | nil, map() | keyword() | nil) :: map()
  def merge_tree_attrs(base_attrs, override_attrs) do
    %{}
    |> merge_layer(base_attrs)
    |> merge_layer(override_attrs)
    |> finalize_class()
  end

  # A rendered node's attrs come from the tree, semantic state, and the
  # adapter only. There are no theme or variant attr layers.
  @spec merge_attr_sources(
          map() | keyword() | nil,
          map() | keyword() | nil,
          map() | keyword() | nil
        ) :: map()
  def merge_attr_sources(tree_attrs, semantic_attrs, adapter_attrs)
      when semantic_attrs in [%{}, [], nil] and adapter_attrs in [%{}, [], nil] and
             is_map(tree_attrs) do
    if normalized_attr_map?(tree_attrs) do
      tree_attrs
    else
      tree_attrs
      |> normalize_attrs()
      |> finalize_class()
    end
  end

  def merge_attr_sources(tree_attrs, semantic_attrs, adapter_attrs) do
    %{}
    |> merge_layer(tree_attrs)
    |> merge_layer(semantic_attrs)
    |> merge_layer(adapter_attrs)
    |> finalize_class()
  end

  @spec normalize_attrs(map() | keyword() | nil) :: map()
  def normalize_attrs(nil), do: %{}

  def normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  def normalize_attrs(attrs) when is_list(attrs) do
    attrs
    |> Enum.into(%{})
    |> normalize_attrs()
  end

  def normalize_attrs(_other), do: %{}

  @spec attr_tokens(term()) :: [String.t()]
  def attr_tokens(value) when value in [nil, false], do: []

  def attr_tokens(value) when is_list(value),
    do: Enum.flat_map(value, &attr_tokens/1)

  def attr_tokens(true), do: []
  def attr_tokens(value), do: [to_string(value)]

  @spec class_tokens(term()) :: [String.t()]
  def class_tokens(value), do: normalize_class(value)

  @spec join_attr_tokens(term()) :: String.t()
  def join_attr_tokens(value), do: value |> attr_tokens() |> Enum.join(" ")

  @spec join_class_tokens(term()) :: String.t()
  def join_class_tokens(value), do: join_classes(value)

  defp merge_layer(acc, attrs) do
    Enum.reduce(normalize_attrs(attrs), acc, fn {key, value}, merged ->
      if key == "class" do
        merge_class(merged, value)
      else
        Map.put(merged, key, value)
      end
    end)
  end

  defp merge_class(attrs, value) do
    classes =
      attrs
      |> Map.get("class")
      |> normalize_class()
      |> Kernel.++(normalize_class(value))

    if classes == [] do
      attrs
    else
      Map.put(attrs, "class", join_classes(classes))
    end
  end

  defp finalize_class(attrs) do
    case Map.get(attrs, "class") do
      nil -> attrs
      class -> Map.put(attrs, "class", join_classes(class))
    end
  end

  defp normalize_class(nil), do: []
  defp normalize_class(false), do: []
  defp normalize_class(""), do: []
  defp normalize_class(class) when is_binary(class), do: String.split(class, ~r/\s+/, trim: true)
  defp normalize_class(class) when is_atom(class), do: [Atom.to_string(class)]
  defp normalize_class(class) when is_list(class), do: Enum.flat_map(class, &normalize_class/1)
  defp normalize_class(other), do: [to_string(other)]

  defp join_classes(classes) do
    classes
    |> normalize_class()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp normalized_attr_map?(attrs) when is_map(attrs) do
    Enum.all?(attrs, fn
      {"class", class} -> is_binary(class)
      {key, _value} -> is_binary(key)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)
end
