defmodule AshUi.DefectClass.DC46RenderAlgebraTest do
  use ExUnit.Case, async: true

  # The render algebra is a FROZEN LiveView-compatible surface: the diff
  # kernel exposes exactly its two entry points, the structs carry exactly
  # the oracle's fields, and the excluded branches (LiveComponents,
  # streams) stay excluded — they are absent from the model, not pending.

  test "diff kernel exposes exactly its two entry points" do
    assert Enum.sort(AshUi.Diff.__info__(:functions)) == [
             {:new_fingerprints, 0},
             {:render, 2}
           ]
  end

  test "algebra structs carry exactly the oracle's fields" do
    assert Enum.sort(Map.keys(%AshUi.Rendered{})) ==
             Enum.sort([:__struct__, :static, :dynamic, :fingerprint, :root, :caller])

    assert Enum.sort(Map.keys(%AshUi.Comprehension{})) ==
             Enum.sort([:__struct__, :static, :entries, :fingerprint, :stream, :has_key?])
  end

  test "excluded branches stay excluded" do
    refute Code.ensure_loaded?(AshUi.Component)
    assert %AshUi.Comprehension{}.stream == nil

    source = File.read!("lib/ash_ui/diff.ex")
    refute source =~ "traverse_component"
    refute source =~ "@stream"
  end

  test "the emitter is the one runtime emission path" do
    # adapters inject struct names; they do not re-emit
    for pkg <- Path.wildcard("packages/*/lib/**/*.ex") do
      source = File.read!(pkg)

      refute source =~ "defp skeleton_rendered",
             "#{pkg} re-implements emission instead of consuming AshUi.Render"
    end
  end
end
