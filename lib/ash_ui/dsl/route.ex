defmodule AshUi.Dsl.Route do
  @moduledoc false

  defstruct [
    :path,
    location: nil,
    params: [],
    queries: [],
    __identifier__: nil,
    __spark_metadata__: nil
  ]

  @schema [
    path: [
      type: :string,
      required: true,
      doc: "The address template. Every :segment must have a declared param."
    ],
    location: [
      type: :any,
      doc:
        "expr(...) of the row's state projecting a handoff address; " <>
          "nil means the route's own template (DESIGN.md §8)."
    ]
  ]

  def schema, do: @schema

  def __entity__ do
    %Spark.Dsl.Entity{
      name: :route,
      target: __MODULE__,
      describe:
        "Declares an address this resource mounts at. Path :segments bind " <>
          "through declared params; query names two-way bind through " <>
          "declared queries. A resource may declare several routes; the " <>
          "first is the canonical projection template.",
      args: [:path],
      schema: schema(),
      entities: [
        params: [%{AshUi.Dsl.RouteParam.__entity__() | identifier: nil}],
        queries: [%{AshUi.Dsl.RouteQuery.__entity__() | identifier: nil}]
      ],
      identifier: :path
    }
  end
end
