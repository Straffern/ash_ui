defmodule AshUi.Dsl.RouteParam do
  @moduledoc false

  defstruct [
    :name,
    :type,
    :state,
    default: nil,
    __identifier__: nil,
    __spark_metadata__: nil
  ]

  @schema [
    name: [type: :atom, required: true],
    type: [type: :atom, default: :string],
    state: [type: :atom],
    default: [type: :any]
  ]

  def schema, do: @schema

  def __entity__ do
    %Spark.Dsl.Entity{
      name: :param,
      target: __MODULE__,
      describe: "Declares a typed route path param.",
      args: [:name, {:optional, :type, :string}],
      schema: schema(),
      identifier: :name
    }
  end
end
