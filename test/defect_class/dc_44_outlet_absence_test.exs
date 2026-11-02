defmodule AshUi.DefectClass.DC44OutletAbsenceTest do
  @moduledoc """
  DC-44: outlet is DELETED (DESIGN §4/§10/§12.7). A host-supplied content
  hole violated render-target neutrality: a target-side data channel
  invisible to `Ash.calculate(:view)`, with no reactivity and no events.
  Shells and chrome are in-model — `render()` children (with fragment
  inputs for caller-supplied regions); the host only picks the root
  resource. Nothing may resurrect the vocabulary.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  @source_globs [
    "lib/**/*.ex",
    "packages/ash_ui_phoenix/lib/**/*.ex"
  ]

  test "no outlet or place-override vocabulary survives anywhere in library source" do
    hits =
      @source_globs
      |> Enum.flat_map(&Path.wildcard(Path.join(@repo_root, &1)))
      |> Enum.flat_map(fn path ->
        source = File.read!(path)

        for term <- ["outlet", "place_overrides", "node: :place"],
            String.contains?(source, term) do
          {Path.relative_to(path, @repo_root), term}
        end
      end)

    assert hits == [], "outlet vocabulary resurrected at: #{inspect(hits)}"
  end

  test "the constructor surface does not export outlet/1" do
    Code.ensure_loaded!(AshUi.ViewConstructor)
    refute function_exported?(AshUi.ViewConstructor, :outlet, 1)
  end

  test "the RenderTree type rejects :outlet nodes as invalid" do
    assert {:error, message: message} =
             Ash.Type.apply_constraints(
               AshUi.Type.RenderTree,
               %{kind: :outlet, child: :active_page},
               []
             )

    assert message =~ "invalid render tree"
  end
end
