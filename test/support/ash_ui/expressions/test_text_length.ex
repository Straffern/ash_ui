defmodule AshUi.Expressions.TestTextLength do
  @moduledoc false
  use Ash.CustomExpression, name: :blueprint_test_text_length, arguments: [[:string]]

  def expression(data_layer, [value])
      when data_layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
    {:ok, expr(fragment(&__MODULE__.text_length/1, ^value))}
  end

  def expression(_data_layer, _args) do
    :unknown
  end

  def text_length(nil) do
    0
  end

  def text_length(value) do
    value |> to_string() |> String.length()
  end
end
