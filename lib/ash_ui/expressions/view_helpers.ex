defmodule AshUi.Expressions.Blank do
  @moduledoc false
  use Ash.CustomExpression, name: :blank?, arguments: [[:term]]

  def expression(data_layer, [value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[value]))}
  end

  def expression(_data_layer, _args), do: :unknown

  def evaluate([value]), do: AshUi.Expr.Blank.blank?(value)
end

defmodule AshUi.Expressions.Present do
  @moduledoc false
  use Ash.CustomExpression, name: :present?, arguments: [[:term]]

  def expression(data_layer, [value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[value]))}
  end

  def expression(_data_layer, _args), do: :unknown

  def evaluate([value]), do: AshUi.Expr.Blank.present?(value)
end

defmodule AshUi.Expressions.Empty do
  @moduledoc false
  use Ash.CustomExpression, name: :empty?, arguments: [[:term]]

  def expression(data_layer, [value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[value]))}
  end

  def expression(_data_layer, _args), do: :unknown

  def evaluate([value]), do: AshUi.Expr.Blank.empty?(value)
end

defmodule AshUi.Expressions.NilifBlank do
  @moduledoc false
  use Ash.CustomExpression, name: :nilif_blank, arguments: [[:term]]

  def expression(data_layer, [value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[value]))}
  end

  def expression(_data_layer, _args), do: :unknown

  def evaluate([value]), do: if(AshUi.Expr.Blank.present?(value), do: value, else: nil)
end

defmodule AshUi.Expressions.Join do
  @moduledoc false
  use Ash.CustomExpression, name: :join, arguments: [[:term, :term]]

  def expression(data_layer, [values, separator])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[values, separator]))}
  end

  def expression(_data_layer, _args), do: :unknown

  def evaluate([values, separator]) do
    if AshUi.Expr.Blank.blank?(values) do
      ""
    else
      values
      |> List.wrap()
      |> Enum.map(&AshUi.Expressions.Formatters.render_string/1)
      |> Enum.join(AshUi.Expressions.Formatters.render_string(separator))
    end
  end
end

defmodule AshUi.Expressions.Count do
  @moduledoc false
  use Ash.CustomExpression, name: :count, arguments: [[:term]]

  def expression(data_layer, [value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[value]))}
  end

  def expression(_data_layer, _args), do: :unknown

  def evaluate([value]) do
    cond do
      AshUi.Expr.Blank.blank?(value) -> 0
      is_list(value) -> length(value)
      is_map(value) -> map_size(value)
      true -> value |> List.wrap() |> length()
    end
  end
end

defmodule AshUi.Expressions.SortBy do
  @moduledoc false
  use Ash.CustomExpression, name: :sort_by, arguments: [[:term, :term, :term], [:term, :term]]

  def expression(data_layer, [values, segments])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[values, segments]))}
  end

  def expression(data_layer, [values, segments, direction])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[values, segments, direction]))}
  end

  def expression(_data_layer, _args), do: :unknown

  def evaluate([values, segments]), do: evaluate([values, segments, :asc])

  def evaluate([values, segments, direction]) do
    values = if AshUi.Expr.Blank.blank?(values), do: [], else: List.wrap(values)
    segments = if is_list(segments), do: segments, else: [segments]
    direction = if direction in [:desc, "desc", :descending], do: :desc, else: :asc

    Enum.sort_by(
      values,
      &AshUi.Expr.Eval.lookup_path(&1, segments),
      &compare(&1, &2, direction)
    )
  end

  defp compare(left, right, :desc), do: compare(right, left, :asc)
  defp compare(left, right, :asc) when left == right, do: true
  defp compare(nil, _right, :asc), do: true
  defp compare(_left, nil, :asc), do: false

  defp compare(left, right, :asc) do
    cond do
      is_binary(left) and is_binary(right) ->
        left <= right

      is_number(left) and is_number(right) ->
        left <= right

      is_atom(left) and is_atom(right) ->
        Atom.to_string(left) <= Atom.to_string(right)

      true ->
        AshUi.Expressions.Formatters.render_string(left) <=
          AshUi.Expressions.Formatters.render_string(right)
    end
  end
end

defmodule AshUi.Expressions.AppendUnique do
  @moduledoc false
  use Ash.CustomExpression, name: :append_unique, arguments: [[:term, :term]]

  def expression(data_layer, [list, value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[list, value]))}
  end

  def expression(_data_layer, _args), do: :unknown

  def evaluate([list, nil]), do: List.wrap(list)
  def evaluate([list, value]), do: list |> List.wrap() |> Kernel.++([value]) |> Enum.uniq()
end

defmodule AshUi.Expressions.FindBy do
  @moduledoc false
  use Ash.CustomExpression, name: :find_by, arguments: [[:term, :term, :term]]

  def expression(data_layer, [items, segments, needle])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[items, segments, needle]))}
  end

  def expression(_data_layer, _args), do: :unknown

  def evaluate([items, segments, needle]) do
    items
    |> List.wrap()
    |> Enum.find(&(AshUi.Expr.Eval.lookup_path(&1, segments) == needle))
  end
end

defmodule AshUi.Expressions.FieldErrors do
  @moduledoc false
  use Ash.CustomExpression, name: :field_errors, arguments: [[:term, :term], [:term]]

  def expression(data_layer, [field])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[field]))}
  end

  def expression(data_layer, [errors, field])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.evaluate/1, ^[errors, field]))}
  end

  def expression(_data_layer, _args), do: :unknown

  # AshUi injects path-scoped errors into the two-argument form before evaluation.
  def evaluate([field]), do: evaluate([[], field])
  def evaluate([errors, field]), do: AshUi.Runtime.Errors.field_errors(errors, field)
end

defmodule AshUi.Expressions.Default do
  @moduledoc false
  use Ash.CustomExpression, name: :default, arguments: [[:term, :term]]

  def expression(data_layer, [value, fallback])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(if(empty?(^value), do: ^fallback, else: ^value))}
  end

  def expression(_data_layer, _args), do: :unknown
end
