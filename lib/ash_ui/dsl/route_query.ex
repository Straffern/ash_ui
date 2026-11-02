defmodule AshUi.Dsl.RouteQuery do
  @moduledoc false

  defstruct [
    :name,
    :type,
    :state,
    default: nil,
    __identifier__: nil,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom() | nil,
          type: atom() | nil,
          state: atom() | nil,
          default: term(),
          __identifier__: term(),
          __spark_metadata__: term()
        }

  @schema [
    name: [type: :atom, required: true],
    type: [type: :atom],
    state: [type: :atom],
    default: [type: :any]
  ]

  def schema, do: @schema

  def __entity__ do
    %Spark.Dsl.Entity{
      name: :query,
      target: __MODULE__,
      describe: "Declares a route query param and optional default.",
      args: [:name, {:optional, :type, nil}],
      schema: schema(),
      identifier: :name
    }
  end
end
