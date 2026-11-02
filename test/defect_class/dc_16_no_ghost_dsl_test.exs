defmodule AshUi.DefectClass.DC16NoGhostDslTest do
  use ExUnit.Case, async: false
  @repo_root Path.expand("../..", __DIR__)
  @lib_root Path.join(@repo_root, "lib")
  test "DC-16 deleted DSL files stay deleted" do
    for path <- [
          "lib/ash_ui/dsl/attribute.ex",
          "lib/ash_ui/dsl/action.ex",
          "lib/ash_ui/dsl/calculation.ex",
          "lib/ash_ui/dsl/child.ex"
        ] do
      refute File.exists?(Path.join(@repo_root, path))
    end
  end

  test "DC-16 children section reads stay deleted" do
    refute lib_source() =~ ~r/get_entities\s*\([^\)]*\[:children\]/s
  end

  defp lib_source do
    @lib_root |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.map_join("\n", &File.read!/1)
  end
end
