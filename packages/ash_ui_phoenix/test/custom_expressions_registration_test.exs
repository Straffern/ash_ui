defmodule AshUi.Phoenix.CustomExpressionsRegistrationTest do
  use ExUnit.Case, async: true

  test "running Ash config registers every canonical AshUi custom expression" do
    registered = Application.fetch_env!(:ash, :custom_expressions) |> MapSet.new()
    canonical = AshUi.Expressions.canonical() |> MapSet.new()

    assert MapSet.subset?(canonical, registered)
  end
end
