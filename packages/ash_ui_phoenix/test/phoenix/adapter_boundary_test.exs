defmodule AshUi.Phoenix.AdapterBoundaryTest do
  use ExUnit.Case, async: true

  @forbidden_internal_refs [
    "AshUi.SafeHTML",
    "AshUi.Runtime",
    "AshUi.RuntimeState",
    "AshUi.ResourceScreen",
    "AshUi.Compiled",
    "AshUi.StaticCompile",
    "AshUi.ResourceBlueprint",
    "AshUi.AppBlueprint",
    "compiled_screen",
    "screen_descriptor",
    "route_descriptor",
    "resource_screen_handler",
    "ResourceScreenChild",
    "resource_screen_operation",
    "screen.private"
  ]

  test "Phoenix adapter source depends only on public AshUi contracts" do
    source =
      Path.expand("../../lib", __DIR__)
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    for forbidden <- @forbidden_internal_refs do
      refute source =~ forbidden
    end

    refute source =~ "AshUi.Adapter"
    assert source =~ "AshUi.EventBinding"
    assert source =~ "AshUi.RenderTarget"
  end
end
