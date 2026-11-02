defmodule AshUi.Expr.Literal do
  @moduledoc false

  def eval!(ast, caller) do
    ast
    |> expand_aliases(caller)
    |> Macro.expand(caller)
    |> decode!()
  rescue
    error in ArgumentError ->
      reraise error, __STACKTRACE__

    # broad rescue: literal macro expansion normalizes arbitrary failures to authoring errors.
    _error ->
      raise ArgumentError, "expected literal quoted term, got: #{Macro.to_string(ast)}"
  end

  defp expand_aliases(ast, caller) do
    Macro.prewalk(ast, fn
      {:__aliases__, _meta, _parts} = alias_ast -> Macro.expand(alias_ast, caller)
      other -> other
    end)
  end

  defp decode!(value)
       when is_atom(value) or is_binary(value) or is_number(value) or is_boolean(value) or
              is_nil(value),
       do: value

  defp decode!({:%{}, _meta, pairs}) when is_list(pairs) do
    Map.new(pairs, fn {key, value} -> {decode!(key), decode!(value)} end)
  end

  defp decode!({:{}, _meta, values}) when is_list(values) do
    values
    |> Enum.map(&decode!/1)
    |> List.to_tuple()
  end

  defp decode!({:__aliases__, _meta, parts}) when is_list(parts), do: Module.concat(parts)

  defp decode!(list) when is_list(list), do: Enum.map(list, &decode!/1)

  defp decode!(tuple) when is_tuple(tuple) and tuple_size(tuple) == 2 do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&decode!/1)
    |> List.to_tuple()
  end

  defp decode!(other) do
    if Macro.quoted_literal?(other) do
      other
    else
      raise ArgumentError
    end
  end
end
