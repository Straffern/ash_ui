defmodule AshUi.Expr.Registry do
  @moduledoc false

  @accessors [
    %{name: :item, marker: :_item, arities: [2], scope_slot: :item_bindings},
    %{name: :index, marker: :_index, arities: [1], scope_slot: :index_bindings},
    %{name: :event, marker: :_event, arities: [1], scope_slot: :dom},
    %{name: :part_id, marker: :_part_id, arities: [1], scope_slot: :part_ids},
    %{name: :result, marker: :_result, arities: [0, 1], scope_slot: :result},
    %{name: :errors, marker: :_errors, arities: [0], scope_slot: :errors},
    %{name: :path_for, marker: :_path_for, arities: [3], scope_slot: :runtime}
  ]

  @markers_by_name Map.new(@accessors, &{&1.name, &1})

  # Syntax aliases only. Value helpers live in Ash's CustomExpression registry.
  @stdlib_calls [
    %{name: :case, arities: [2]},
    %{name: :path, arities: [2]}
  ]

  @stdlib_by_name Map.new(@stdlib_calls, &{&1.name, &1})
  @native_ash_functions Ash.Filter.builtin_functions()

  def all, do: @accessors
  def accessors, do: @accessors
  def stdlib_calls, do: @stdlib_calls

  def fetch(name) when is_atom(name), do: Map.fetch(@markers_by_name, name)
  def fetch(_name), do: :error

  def fetch_stdlib(name) when is_atom(name), do: Map.fetch(@stdlib_by_name, name)
  def fetch_stdlib(_name), do: :error

  def stdlib_name?(name) when is_atom(name), do: Map.has_key?(@stdlib_by_name, name)
  def stdlib_name?(_name), do: false

  def fetch_native_ash_function(name, arity) when is_atom(name) and is_integer(arity) do
    case Enum.find(@native_ash_functions, fn module ->
           module.name() == name and native_ash_arity?(module.args(), arity)
         end) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  def fetch_native_ash_function(_name, _arity), do: :error

  def accessor_name?(name) when is_atom(name), do: Map.has_key?(@markers_by_name, name)
  def accessor_name?(_name), do: false

  def reserved_name?(name) when is_atom(name), do: accessor_name?(name) or stdlib_name?(name)
  def reserved_name?(_name), do: false

  def constructor_name?(name) when is_atom(name) do
    AshUi.ViewConstructor.constructor_name?(name)
  end

  def constructor_name?(_name), do: false

  def valid_stdlib_arity?(name, arity) when is_atom(name) and is_integer(arity) do
    case fetch_stdlib(name) do
      {:ok, call} -> valid_arity?(call, arity)
      :error -> false
    end
  end

  def valid_stdlib_arity?(_name, _arity), do: false

  def valid_accessor_arity?(name, arity) when is_atom(name) and is_integer(arity) do
    case fetch(name) do
      {:ok, accessor} -> valid_arity?(accessor, arity)
      :error -> false
    end
  end

  def valid_accessor_arity?(_name, _arity), do: false

  def marker_tuple?(tuple) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    marker = elem(tuple, 0)
    arity = tuple_size(tuple) - 1

    Enum.any?(@accessors, fn accessor ->
      accessor.marker == marker and valid_arity?(accessor, arity)
    end)
  end

  def marker_tuple?(_other), do: false

  def known_marker?(marker) when is_atom(marker),
    do: Enum.any?(@accessors, &(&1.marker == marker))

  def known_marker?(_marker), do: false

  def accessor_name(marker, arity) when is_atom(marker) and is_integer(arity) do
    Enum.find_value(@accessors, fn
      %{marker: ^marker, arities: arities, name: name} ->
        if arity in arities, do: name

      _other ->
        nil
    end)
  end

  def accessor_name(_marker, _arity), do: nil

  def scope_slot(marker, arity) when is_atom(marker) and is_integer(arity) do
    Enum.find_value(@accessors, fn
      %{marker: ^marker, arities: arities, scope_slot: scope_slot} ->
        if arity in arities, do: scope_slot

      _other ->
        nil
    end)
  end

  def scope_slot(_marker, _arity), do: nil

  defp valid_arity?(%{arities: arities}, arity), do: arity in arities
  defp valid_arity?(%{min_arity: min_arity}, arity), do: arity >= min_arity

  defp native_ash_arity?(:var_args, _arity), do: true

  defp native_ash_arity?(signatures, arity) when is_list(signatures),
    do: Enum.any?(signatures, &(length(&1) == arity))
end
