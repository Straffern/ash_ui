defmodule AshUi.DefectClass.DC36SkeletonTest do
  @moduledoc """
  DC-36: the compiled target skeleton is byte-aligned with the full
  renderer. Weaving skeleton statics with evaluated dynamics must produce
  the SAME HTML as rendering the materialized tree through
  `RenderTarget.Html` — for every record state, including branch flips and
  keyed insert/remove/reorder. The skeleton is the statics contract the
  target host ships to the client once; any byte drift means stale or
  corrupt DOM after patches.
  """
  use ExUnit.Case, async: false

  alias AshUi.Expr.Scope
  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Evaluator
  alias AshUi.PatchFixtures
  alias AshUi.PatchFixtures.{Page, ShellPage}

  # ── full paint from the skeleton (statics + evaluated dynamics) ───────────

  defp paint(skeleton, record, resource, extra_scope_opts \\ []) do
    scope =
      Scope.new(record, %{}, [ash_resource_module: resource] ++ extra_scope_opts)

    weave(skeleton.statics, Enum.map(skeleton.dynamics, &paint_dyn(&1, scope, record)))
    |> IO.iodata_to_binary()
  end

  defp paint_dyn({:text, _addr, eval}, scope, _record) do
    Evaluator.eval(eval, scope) |> AshUi.RenderTarget.Html.text_content() |> safe_iodata()
  end

  defp paint_dyn({:attrs, _addr, eval}, scope, _record) do
    Evaluator.eval(eval, scope)
  end

  defp paint_dyn({:branch, _addr, cond_eval, arms}, scope, record) do
    arm = if truthy?(Evaluator.eval(cond_eval, scope)), do: arms.true, else: arms.false

    case arm do
      nil -> ""
      skeleton -> paint(skeleton, record, scope.ash_resource_module)
    end
  end

  defp paint_dyn({:keyed, _addr, items_eval, item}, scope, record) do
    Evaluator.eval(items_eval, scope)
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      opts =
        if item.index in [nil, item.as],
          do: [item_bindings: %{item.as => entry}],
          else: [item_bindings: %{item.as => entry}, index_bindings: %{item.index => index}]

      paint(item.skeleton, record, scope.ash_resource_module, opts)
    end)
  end

  defp paint_dyn({:child, _addr, resource, input_eval, _embedded?}, scope, _record) do
    # The enriched skeleton ref carries the child input evaluator resolved
    # at compile time.
    table = Compiler.table(resource)
    record = struct(resource, Evaluator.eval(input_eval, scope))
    paint(table.skeleton, record, resource)
  end

  defp weave([s | statics], [d | dynamics]), do: [s, d | weave(statics, dynamics)]
  defp weave([s], []), do: [s]

  defp safe_iodata(value), do: AshUi.RenderTarget.Html.safe_to_iodata(value)

  defp truthy?(value), do: value not in [nil, false]

  # ── the legacy full renderer (the oracle) ─────────────────────────────────

  defp legacy_paint(resource, record) do
    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(resource),
        record,
        %{},
        []
      )

    {:safe, iodata} = AshUi.RenderTarget.Html.render_static(tree)
    IO.iodata_to_binary(iodata)
  end

  # ── gates ──────────────────────────────────────────────────────────────────

  test "skeleton paint is byte-identical to the full renderer across record states" do
    table = Compiler.table(Page)
    assert %AshUi.Patch.Skeleton{} = table.skeleton
    assert table.skeleton.statics != []

    page =
      PatchFixtures.seed([
        PatchFixtures.fold("m1"),
        PatchFixtures.fold("m2", true),
        PatchFixtures.fold("m3")
      ])

    assert paint(table.skeleton, page, Page) == legacy_paint(Page, page)

    # scalar change
    page = PatchFixtures.run!(page, :retitle, %{title: "Archive"})
    assert paint(table.skeleton, page, Page) == legacy_paint(Page, page)

    # keyed content change
    page = PatchFixtures.toggle_fold(page, "m1")
    assert paint(table.skeleton, page, Page) == legacy_paint(Page, page)

    # keyed remove + insert + reorder
    page =
      PatchFixtures.run!(page, :put_folds, %{
        folds: [
          PatchFixtures.fold("m9"),
          PatchFixtures.fold("m3"),
          PatchFixtures.fold("m1", true)
        ]
      })

    assert paint(table.skeleton, page, Page) == legacy_paint(Page, page)

    # empty collection
    page = PatchFixtures.run!(page, :put_folds, %{folds: []})
    assert paint(table.skeleton, page, Page) == legacy_paint(Page, page)
  end

  test "nested render(Resource, input) skeleton stays byte-aligned" do
    table = Compiler.table(ShellPage)

    shell =
      Ash.Seed.seed!(ShellPage, %{session_id: Ash.UUID.generate(), badge_label: "urgent"})

    assert paint(table.skeleton, shell, ShellPage) == legacy_paint(ShellPage, shell)
  end
end
