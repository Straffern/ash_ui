defmodule AshUi.Expressions do
  @moduledoc "Canonical custom expressions that consuming applications register with Ash."

  @canonical [
    AshUi.Expressions.ToString,
    AshUi.Expressions.Humanize,
    AshUi.Expressions.RelativeTime,
    AshUi.Expressions.TimeAgoInWords,
    AshUi.Expressions.Truncate,
    AshUi.Expressions.StripPrefix,
    AshUi.Expressions.ClassJoin,
    AshUi.Expressions.Blank,
    AshUi.Expressions.Present,
    AshUi.Expressions.Empty,
    AshUi.Expressions.NilifBlank,
    AshUi.Expressions.Join,
    AshUi.Expressions.Count,
    AshUi.Expressions.SortBy,
    AshUi.Expressions.AppendUnique,
    AshUi.Expressions.FindBy,
    AshUi.Expressions.FieldErrors,
    AshUi.Expressions.Default
  ]

  @spec canonical() :: [module()]
  def canonical, do: @canonical

  @doc false
  def evaluate!(expression) do
    case Ash.Expr.eval(expression, unknown_on_unknown_refs?: true) do
      {:ok, value} ->
        value

      :unknown ->
        raise ArgumentError, "unresolvable Ash expression: #{inspect(expression)}"

      {:error, error} ->
        raise ArgumentError, "Ash expression evaluation failed: #{inspect(error)}"
    end
  end

  @doc false
  def literal(value)
      when is_atom(value) or is_binary(value) or is_number(value) or is_function(value),
      do: value

  def literal(value), do: %Ash.Query.Function.Fragment{arguments: [fn -> value end]}

  @doc false
  def defer(expression),
    do: %Ash.Query.Function.Fragment{arguments: [fn -> evaluate!(expression) end]}
end

defmodule AshUi.Expressions.Formatters do
  @moduledoc false

  alias AshUi.Expr.Blank

  def humanize(value) when is_atom(value) do
    value |> Atom.to_string() |> humanize()
  end

  def humanize(value) when is_binary(value) do
    String.replace(value, "_", " ")
  end

  def humanize(value) do
    if Blank.blank?(value), do: "", else: value |> to_string() |> humanize()
  end

  def truncate(value, count) do
    value = render_string(value)
    count = normalize_count(count)

    cond do
      count <= 0 -> ""
      String.length(value) <= count -> value
      count == 1 -> "…"
      true -> String.slice(value, 0, count - 1) <> "…"
    end
  end

  def strip_prefix(value, prefix) do
    value = render_string(value)
    prefix = render_string(prefix)

    if prefix != "" and String.starts_with?(value, prefix) do
      String.replace_prefix(value, prefix, "")
    else
      value
    end
  end

  def relative_time(%DateTime{} = datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime)

    cond do
      diff <= 5 -> "now"
      diff <= 60 -> pluralize(diff, "second")
      diff <= 3_600 -> pluralize(div(diff, 60), "minute")
      diff <= 86_400 -> pluralize(div(diff, 3_600), "hour")
      diff <= 604_800 -> pluralize(div(diff, 86_400), "day")
      diff <= 2_592_000 -> pluralize(div(diff, 604_800), "week")
      diff <= 31_536_000 -> pluralize(div(diff, 2_592_000), "month")
      true -> "over a year ago"
    end
  end

  def relative_time(other), do: Kernel.to_string(other)

  def class_join(entries) do
    entries
    |> normalize_classes()
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  def render_string(value) do
    cond do
      Blank.blank?(value) -> ""
      String.Chars.impl_for(value) -> to_string(value)
      true -> inspect(value)
    end
  end

  defp normalize_count(count) when is_integer(count), do: count

  defp normalize_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {value, _rest} -> value
      :error -> 0
    end
  end

  defp normalize_count(_count), do: 0

  defp pluralize(1, unit), do: "1 #{unit} ago"
  defp pluralize(count, unit), do: "#{count} #{unit}s ago"

  defp normalize_classes({condition, class}) do
    %Ash.Query.Function.If{
      arguments: [
        AshUi.Expressions.literal(condition),
        AshUi.Expressions.literal(class),
        nil
      ]
    }
    |> AshUi.Expressions.evaluate!()
    |> normalize_classes()
  end

  defp normalize_classes(nil), do: []
  defp normalize_classes(""), do: []

  defp normalize_classes(class) when is_binary(class),
    do: String.split(class, ~r/\s+/, trim: true)

  defp normalize_classes(class) when is_atom(class), do: [Atom.to_string(class)]

  defp normalize_classes(class) when is_list(class),
    do: Enum.flat_map(class, &normalize_classes/1)

  defp normalize_classes(class), do: [to_string(class)]
end

defmodule AshUi.Expressions.Humanize do
  @moduledoc false

  use Ash.CustomExpression,
    name: :humanize,
    arguments: [
      [:term]
    ]

  def expression(data_layer, [value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.humanize/1, ^value))}
  end

  def expression(_data_layer, _args), do: :unknown

  def humanize(value), do: AshUi.Expressions.Formatters.humanize(value)
end

defmodule AshUi.Expressions.RelativeTime do
  @moduledoc false

  use Ash.CustomExpression,
    name: :relative_time,
    arguments: [
      [:term]
    ]

  def expression(data_layer, [value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.relative_time/1, ^value))}
  end

  def expression(_data_layer, _args), do: :unknown

  def relative_time(value), do: AshUi.Expressions.Formatters.relative_time(value)
end

defmodule AshUi.Expressions.TimeAgoInWords do
  @moduledoc false

  use Ash.CustomExpression,
    name: :time_ago_in_words,
    arguments: [
      [:term]
    ]

  def expression(data_layer, [value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.time_ago_in_words/1, ^value))}
  end

  def expression(_data_layer, _args), do: :unknown

  def time_ago_in_words(value), do: AshUi.Expressions.Formatters.relative_time(value)
end

defmodule AshUi.Expressions.Truncate do
  @moduledoc false

  use Ash.CustomExpression,
    name: :truncate,
    arguments: [
      [:term, :term]
    ]

  def expression(data_layer, [value, count])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.truncate/2, ^value, ^count))}
  end

  def expression(_data_layer, _args), do: :unknown

  def truncate(value, count), do: AshUi.Expressions.Formatters.truncate(value, count)
end

defmodule AshUi.Expressions.StripPrefix do
  @moduledoc false

  use Ash.CustomExpression,
    name: :strip_prefix,
    arguments: [
      [:term, :term]
    ]

  def expression(data_layer, [value, prefix])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.strip_prefix/2, ^value, ^prefix))}
  end

  def expression(_data_layer, _args), do: :unknown

  def strip_prefix(value, prefix),
    do: AshUi.Expressions.Formatters.strip_prefix(value, prefix)
end

defmodule AshUi.Expressions.ClassJoin do
  @moduledoc false

  use Ash.CustomExpression,
    name: :__class_join__,
    arguments: [
      [:term]
    ]

  def expression(data_layer, [entries])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    entries =
      if is_list(entries) do
        Enum.map(entries, fn
          {condition, class} ->
            %Ash.Query.Function.If{arguments: [condition, class, nil]}

          class ->
            class
        end)
      else
        entries
      end

    {:ok, expr(fragment(&__MODULE__.class_join/1, ^entries))}
  end

  def expression(_data_layer, _args), do: :unknown

  def class_join(entries), do: AshUi.Expressions.Formatters.class_join(entries)
end

defmodule AshUi.Expressions.ToString do
  @moduledoc false

  # to_string is NOT a native Ash function (registry-verified) — this is
  # the sanctioned extension point, one definition serving SQL-capable
  # layers via fragment and runtime evaluation alike.
  use Ash.CustomExpression,
    name: :to_string,
    arguments: [
      [:term]
    ]

  def expression(data_layer, [value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.stringify/1, ^value))}
  end

  def expression(_data_layer, _args), do: :unknown

  def stringify(value), do: Kernel.to_string(value)
end
