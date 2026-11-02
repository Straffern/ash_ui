defmodule AshUi.DefectClass.DC42InliningEquivalenceTest do
  @moduledoc """
  DC-42: compile-time child inlining is BEHAVIOR-PRESERVING — an embedded,
  event-free child renders byte-identically whether spliced at compile time
  or crossed at runtime, and every non-inlinable child keeps its runtime
  boundary with the ONE key language intact.

  Contract matrix:
   1. a depth-3 pure-display chain collapses into parent-rooted slots: no
      :child slots, no child tables, no {:child, ...} skeleton dynamics;
      the leaf dep substitutes to the parent field and propagation routes a
      parent change to exactly the inlined slot
   2. inlined skeleton paint is byte-identical to the runtime semantic
      renderer (which crosses children at runtime) across record states —
      the equivalence oracle that makes inlining unobservable
   3. an event-bearing embedded child does NOT inline: its :child slot,
      child table, and event-index boundary survive, and the SEMANTIC
      renderer emits the same chain+address binding key the live path and
      the resolver use (`v-2.v.click`) — never ordinal node paths
   4. dispatch reachability: the event child's key resolves to an embedded
      target on the CURRENT record; a key aimed into an inlined subtree is
      an ordinary unknown target (:error), never a silent no-op
  """
  use ExUnit.Case, async: false

  alias AshUi.Expr.Scope
  alias AshUi.Patch.Bindings
  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Runtime, as: PatchRuntime

  # ── fixtures ────────────────────────────────────────────────────────────────

  defmodule Leaf do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, primary_key?: true, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(box([], [text("leaf: "), text(label)]))
      )
    end
  end

  defmodule Mid do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, primary_key?: true, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section([], [
            render(AshUi.DefectClass.DC42InliningEquivalenceTest.Leaf, %{label: label})
          ])
        )
      )
    end
  end

  defmodule ActionChip do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, primary_key?: true, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])

      update :poke do
        require_atomic?(false)
        change(set_attribute(:label, "poked"))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(button(:poke, [type: :button, on_click: :poke], [text("chip: "), text(label)]))
      )
    end
  end

  defmodule ChangedLeaf do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, primary_key?: true, allow_nil?: false, public?: true)
    end

    actions do
      create :create do
        primary?(true)
        accept([:label])
        change(set_attribute(:label, "created"))
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text(label)))
    end
  end

  defmodule DerivedLeaf do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, primary_key?: true, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end

    calculations do
      calculate(:decorated, :string, expr("derived:" <> label))
      calculate(:view, AshUi.Type.RenderTree, expr(text(decorated)))
    end
  end

  defmodule ChainPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:banner, :string, allow_nil?: false, default: "hello", public?: true)
      attribute(:unrelated, :string, allow_nil?: false, default: "x", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :rebanner do
        require_atomic?(false)
        argument(:banner, :string, allow_nil?: false)
        change(set_attribute(:banner, arg(:banner)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section([], [
            render(AshUi.DefectClass.DC42InliningEquivalenceTest.Mid, %{label: banner})
          ])
        )
      )
    end
  end

  defmodule MixedPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:note, :string, allow_nil?: false, default: "n1", public?: true)
      attribute(:banner, :string, allow_nil?: false, default: "b1", public?: true)

      attribute(:chip, AshUi.DefectClass.DC42InliningEquivalenceTest.ActionChip,
        allow_nil?: false,
        public?: true
      )
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section([], [
            box([], [text(note)]),
            render(AshUi.DefectClass.DC42InliningEquivalenceTest.Leaf, %{label: banner}),
            render(AshUi.DefectClass.DC42InliningEquivalenceTest.ActionChip, chip)
          ])
        )
      )
    end
  end

  defmodule SemanticBoundaryPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:label, :string, allow_nil?: false, default: "value", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section([], [
            render(AshUi.DefectClass.DC42InliningEquivalenceTest.ChangedLeaf, %{
              label: label
            }),
            render(AshUi.DefectClass.DC42InliningEquivalenceTest.DerivedLeaf, %{
              label: label
            })
          ])
        )
      )
    end
  end

  # ── skeleton paint harness (dc_36 idiom, enriched child refs) ──────────────

  defp paint(skeleton, record, resource, extra_scope_opts \\ []) do
    scope =
      Scope.new(record, %{}, [ash_resource_module: resource] ++ extra_scope_opts)

    weave(skeleton.statics, Enum.map(skeleton.dynamics, &paint_dyn(&1, scope, record)))
    |> IO.iodata_to_binary()
  end

  defp paint_dyn({:text, _addr, eval}, scope, _record) do
    AshUi.Patch.Evaluator.eval(eval, scope)
    |> AshUi.RenderTarget.Html.text_content()
    |> safe_iodata()
  end

  defp paint_dyn({:attrs, _addr, eval}, scope, _record),
    do: AshUi.Patch.Evaluator.eval(eval, scope)

  defp paint_dyn({:branch, _addr, cond_eval, arms}, scope, record) do
    case if(AshUi.Patch.Evaluator.eval(cond_eval, scope) not in [nil, false],
           do: arms.true,
           else: arms.false
         ) do
      nil -> ""
      skeleton -> paint(skeleton, record, scope.ash_resource_module)
    end
  end

  defp paint_dyn({:keyed, _addr, items_eval, item}, scope, record) do
    AshUi.Patch.Evaluator.eval(items_eval, scope)
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

  # Runtime child crossing: thread the binding chain exactly as the live
  # renderer and the semantic renderer do — the child's event keys must be
  # chain + child-local stamped address.
  defp paint_dyn({:child, addr, resource, input_eval, _embedded?}, scope, _record) do
    table = Compiler.table(resource)

    record =
      case AshUi.Patch.Evaluator.eval(input_eval, scope) do
        %{__struct__: ^resource} = struct -> struct
        input when is_map(input) -> struct(resource, input)
      end

    chain =
      Map.get(scope.context, :__bp_binding_chain__, []) ++ [Compiler.addr_component(addr)]

    paint(table.skeleton, record, resource, context: %{__bp_binding_chain__: chain})
  end

  defp weave([s | statics], [d | dynamics]), do: [s, d | weave(statics, dynamics)]
  defp weave([s], []), do: [s]

  defp safe_iodata(value), do: AshUi.RenderTarget.Html.safe_to_iodata(value)

  defp semantic_paint(resource, record) do
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

  defp all_slots(table) do
    Enum.flat_map(table.slots, fn
      {_id, %{kind: :keyed_list, meta: %{item_slots: item_slots}} = slot} ->
        [slot | Map.values(item_slots)]

      {_id, slot} ->
        [slot]
    end)
  end

  defp seed(resource, attrs) do
    Ash.Seed.seed!(resource, Map.put(attrs, :session_id, Ash.UUID.generate()))
  end

  # ── gate 1: depth-3 chain collapses ─────────────────────────────────────────

  test "gate 1: an event-free embedded chain collapses into parent-rooted slots" do
    table = Compiler.table(ChainPage)
    slots = all_slots(table)

    refute Enum.any?(slots, &(&1.kind == :child)),
           "pure chain must leave no :child slots"

    assert table.children == %{}, "pure chain must compile no child tables"

    refute Enum.any?(table.skeleton.dynamics, &match?({:child, _, _, _, _}, &1)),
           "pure chain must leave no child skeleton dynamics"

    # the leaf's `label` ref substituted through Mid down to the parent field
    leaf_slot = Enum.find(slots, &(&1.kind == :text and &1.deps == [:banner]))
    assert leaf_slot, "expected the inlined leaf text slot depending on :banner"

    page = seed(ChainPage, %{})

    assert PatchRuntime.changed_addresses(table, page, %{page | banner: "new"}) ==
             MapSet.new([leaf_slot.addr])

    assert PatchRuntime.changed_addresses(table, page, %{page | unrelated: "y"}) == MapSet.new()
  end

  # ── gate 2: byte equivalence ────────────────────────────────────────────────

  test "gate 2: inlined skeleton paint is byte-identical to the runtime semantic renderer" do
    table = Compiler.table(ChainPage)

    page = seed(ChainPage, %{})
    assert paint(table.skeleton, page, ChainPage) == semantic_paint(ChainPage, page)

    changed = %{page | banner: "changed"}
    assert paint(table.skeleton, changed, ChainPage) == semantic_paint(ChainPage, changed)
  end

  # ── gate 3: event-bearing child keeps its boundary + ONE key language ──────

  test "gate 3: an event-bearing embedded child keeps its boundary and address-format keys" do
    table = Compiler.table(MixedPage)
    slots = all_slots(table)

    child_slots = Enum.filter(slots, &(&1.kind == :child))
    assert [chip_slot] = child_slots, "exactly the event-bearing child must survive inlining"
    assert chip_slot.meta.resource == ActionChip

    assert Map.keys(table.children) == [chip_slot.addr]

    assert %{child_boundary: true} = table.event_elements[chip_slot.addr],
           "the child crossing must be indexed for dispatch"

    # the SEMANTIC renderer must emit the same chain+address key the live
    # path ships and the resolver accepts — never ordinal node paths
    page = seed(MixedPage, %{chip: %{label: "c1"}})
    chip_component = Compiler.addr_component(chip_slot.addr)
    html = semantic_paint(MixedPage, page)

    assert html =~ ~s(data-ash-ui-binding="#{chip_component}.v.click"),
           "semantic child keys must be chain+address format, got: #{html}"

    refute html =~ ~r/data-ash-ui-binding="i\d/,
           "ordinal node-path keys must never leak: #{html}"

    # and the skeleton paint stays byte-identical across the boundary
    assert paint(table.skeleton, page, MixedPage) == semantic_paint(MixedPage, page)

    poked = %{page | chip: %{page.chip | label: "c2"}}
    assert paint(table.skeleton, poked, MixedPage) == semantic_paint(MixedPage, poked)
  end

  # ── gate 4: dispatch reachability ───────────────────────────────────────────

  test "gate 4: the event child resolves to an embedded target; inlined subtrees are unknown targets" do
    table = Compiler.table(MixedPage)
    [chip_slot] = Enum.filter(all_slots(table), &(&1.kind == :child))
    chip_component = Compiler.addr_component(chip_slot.addr)

    page = seed(MixedPage, %{chip: %{label: "c1"}})

    assert {:ok, binding, target} = Bindings.resolve(page, "#{chip_component}.v.click")
    assert binding.ui_event == :poke
    assert match?({:embedded, _parent, _path}, target)

    # the inlined Leaf sits at v/1: no boundary exists there — an ordinary
    # unknown target, exactly like a stale key
    assert :error = Bindings.resolve(page, "v-1.v.click")
  end

  test "gate 5: Ash changes and non-view calculations retain the child boundary" do
    table = Compiler.table(SemanticBoundaryPage)

    assert table.slots
           |> Map.values()
           |> Enum.filter(&(&1.kind == :child))
           |> Enum.map(& &1.meta.resource)
           |> Enum.sort() == Enum.sort([ChangedLeaf, DerivedLeaf])

    assert {:ok, %ChangedLeaf{label: "created"}} =
             AshUi.build_child_record(ChangedLeaf, %{label: "value"})
  end
end
