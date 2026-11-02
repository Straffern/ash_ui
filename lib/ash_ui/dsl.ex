defmodule AshUi.Dsl do
  @moduledoc false

  alias AshUi.Dsl.{RouteParam, RouteQuery}

  @config %Spark.Dsl.Section{
    name: :ash_ui,
    top_level?: true,
    describe: "AshUi compile-time configuration.",
    imports: [AshUi.Expr],
    schema: [
      strict_expressions?: [
        type: {:one_of, [:off, :warn, :strict]},
        default: :strict,
        doc: "Controls compile-time expression verification."
      ],
      stylesheets: [
        type: {:list, :string},
        default: [],
        doc:
          "Stylesheet file paths (relative to the declaring resource's project " <>
            "root) for a document-producing (routed) resource. Each entry is " <>
            "simultaneously a compile-time build input — its `[part=...]` rules " <>
            "are verified against the resource's render closure — and the served " <>
            "href, linked in declared order and resolved relative to the document " <>
            "base. See DESIGN.md §9."
      ]
    ]
  }

  @route %Spark.Dsl.Section{
    name: :route,
    describe: "Route-local query metadata for a blueprint resource.",
    entities: [
      RouteParam.__entity__(),
      RouteQuery.__entity__()
    ]
  }

  @routes %Spark.Dsl.Section{
    name: :routes,
    describe:
      "The addresses this resource mounts at. Path :segments and query " <>
        "names two-way bind to same-named state; the first route is the " <>
        "canonical projection template. ALL routing derives from these " <>
        "declarations.",
    entities: [
      AshUi.Dsl.Route.__entity__()
    ]
  }

  def sections,
    do: [
      @config,
      @route,
      @routes
    ]
end
