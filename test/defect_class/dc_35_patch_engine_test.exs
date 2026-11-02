defmodule AshUi.DefectClass.DC35PatchEngineTest do
  @moduledoc """
  DC-35: the changed-address contract. The patching protocol is
  LiveView's — core contributes ONLY the compiled table (slots +
  propagation + skeleton) and `changed_addresses/3`. These gates pin the
  invalidation semantics: precision (a change reaches exactly the slots
  whose deps it touches), completeness, and the :all collapse for missing
  before-images. Value-level and wire-level correctness live in the
  phoenix package's LiveRender gates, driven by Phoenix.LiveView.Diff
  itself.
  """
  use ExUnit.Case, async: false

  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Runtime
  alias AshUi.PatchFixtures
  alias AshUi.PatchFixtures.Page

  test "table compiles slots, propagation, keyed anchors, and a skeleton from the real view calculation" do
    table = Compiler.table(Page)

    kinds = table.slots |> Map.values() |> Enum.map(& &1.kind) |> Enum.frequencies()
    assert kinds[:keyed_list] == 1

    assert %AshUi.Patch.Skeleton{} = table.skeleton
    assert :folds in Map.keys(table.propagation)
    assert :title in Map.keys(table.propagation)
    assert :selected_id in Map.keys(table.propagation)

    # disjointness: title reaches no folds slots and vice versa
    title_slots = MapSet.new(table.propagation[:title])
    folds_slots = MapSet.new(table.propagation[:folds])
    assert MapSet.disjoint?(title_slots, folds_slots)
  end

  test "scalar change reaches only scalar slots; collection change reaches the keyed slot" do
    table = Compiler.table(Page)
    page = PatchFixtures.seed([PatchFixtures.fold("m1"), PatchFixtures.fold("m2")])

    {_id, keyed_slot} = Enum.find(table.slots, fn {_id, s} -> s.kind == :keyed_list end)

    retitled = PatchFixtures.run!(page, :retitle, %{title: "Archive"})
    changed = Runtime.changed_addresses(table, page, retitled)
    assert MapSet.size(changed) > 0
    refute MapSet.member?(changed, keyed_slot.addr)

    toggled = PatchFixtures.toggle_fold(retitled, "m1")
    changed = Runtime.changed_addresses(table, retitled, toggled)
    assert MapSet.member?(changed, keyed_slot.addr)
  end

  test "changed set is empty for a no-op and :all without a before-image" do
    table = Compiler.table(Page)
    page = PatchFixtures.seed([PatchFixtures.fold("m1")])

    assert Runtime.changed_addresses(table, page, page) == MapSet.new()
    assert Runtime.changed_addresses(table, nil, page) == :all
  end

  test "changed-set derivation stays flat at 10k folds" do
    folds = for n <- 1..10_000, do: PatchFixtures.fold("m-#{n}")
    page = PatchFixtures.seed(folds)
    new_page = PatchFixtures.toggle_fold(page, "m-4217")

    table = Compiler.table(Page)

    {us, changed} = :timer.tc(fn -> Runtime.changed_addresses(table, page, new_page) end)

    # field-level compare + propagation lookup — no per-item work
    assert MapSet.size(changed) >= 1
    assert us < 100_000, "changed_addresses took #{us}µs at 10k folds"
  end

  test "the parallel op vocabulary is deleted" do
    refute function_exported?(Runtime, :mount, 3)
    refute function_exported?(Runtime, :apply_change, 4)
    refute function_exported?(Runtime, :hint, 1)
  end
end
