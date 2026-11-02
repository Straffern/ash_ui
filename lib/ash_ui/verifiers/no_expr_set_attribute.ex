defmodule AshUi.Verifiers.NoExprSetAttribute do
  @moduledoc false

  # Native Ash `set_attribute/2,3` casts eagerly. It accepts direct Ash
  # argument and context templates, but arbitrary expression-valued
  # assignments fail later at action invocation. AshUi resources fail
  # those at compile time.

  use Spark.Dsl.Verifier

  alias Ash.Query.Call
  alias AshUi.Verifiers.Helpers
  alias Spark.Dsl.Transformer

  @guidance "set_attribute cannot evaluate arbitrary expressions at runtime; use a direct arg(:x) or context(:x) template, atomic_update(:attr, expr(...)) for computed values, or an inline change fn"

  @impl true
  def verify(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.find_value(:ok, fn action ->
      case action |> Map.get(:changes, []) |> Enum.find(&expr_set_attribute_change?/1) do
        nil ->
          false

        change ->
          attribute = set_attribute_name(change)

          raise Helpers.dsl_error(
                  dsl_state,
                  [:actions, action.name, :changes, attribute || :set_attribute],
                  @guidance
                )
      end
    end)
  end

  defp expr_set_attribute_change?(%Ash.Resource.Change{
         change: {Ash.Resource.Change.SetAttribute, opts}
       }) do
    opts |> Keyword.get(:value) |> expression_value?()
  end

  defp expr_set_attribute_change?({Ash.Resource.Change.SetAttribute, opts}) when is_list(opts) do
    opts |> Keyword.get(:value) |> expression_value?()
  end

  defp expr_set_attribute_change?(_change), do: false

  defp set_attribute_name(%Ash.Resource.Change{
         change: {Ash.Resource.Change.SetAttribute, opts}
       }) do
    Keyword.get(opts, :attribute)
  end

  defp set_attribute_name({Ash.Resource.Change.SetAttribute, opts}) when is_list(opts) do
    Keyword.get(opts, :attribute)
  end

  defp set_attribute_name(_change), do: nil

  defp expression_value?(value) do
    if direct_template?(value), do: false, else: expression_term?(value)
  end

  defp direct_template?({kind, name})
       when kind in [:_arg, :_context] and (is_atom(name) or is_binary(name)),
       do: true

  defp direct_template?(%Call{name: name, args: [key], operator?: false})
       when name in [:arg, :context] and (is_atom(key) or is_binary(key)),
       do: true

  defp direct_template?(_value), do: false

  defp expression_term?(%Call{}), do: true
  defp expression_term?(%{__struct__: Ash.Expr}), do: true
  defp expression_term?({:_arg, name}) when is_atom(name) or is_binary(name), do: true
  defp expression_term?({:_ref, path, name}) when is_list(path) and is_atom(name), do: true
  defp expression_term?({:_context, name}) when is_atom(name) or is_binary(name), do: true
  defp expression_term?({:_parent, _meta, _expr}), do: true

  defp expression_term?(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> expression_term?()
  end

  defp expression_term?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} -> expression_term?(key) or expression_term?(value) end)
  end

  defp expression_term?(list) when is_list(list), do: Enum.any?(list, &expression_term?/1)

  defp expression_term?(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.any?(&expression_term?/1)
  end

  defp expression_term?(_value), do: false
end
