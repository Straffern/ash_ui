defmodule AshUi.DefectClass.DC38SkeletonMatrixTest do
  @moduledoc """
  DC-38: the differential-render skeleton compiler nesting matrix + the
  changed-address derivation.

  The compiled skeleton (statics + evaluator dynamics) must paint
  byte-identically to the legacy full renderer for EVERY structural nesting
  the view DSL can author — branch inside keyed item, keyed list inside a
  branch arm, keyed list inside a keyed item (nested collections), child
  render inside a keyed item, keyed list inside a child resource's view —
  across record states including branch flips both ways and
  empty→nonempty→empty collections. Entry identity must implement Ash
  resource identity (authored `key:` expr > full composite-pk tuple > id >
  ordinal), a declared `index:` alias must flow through index_bindings (not
  item_bindings), and `changed_addresses/3` must reach EXACTLY the
  propagation-affected slot addresses per changed field, with
  `%Ash.NotLoaded{}` fields unchanged only when unloaded on BOTH sides.
  """
  use ExUnit.Case, async: false

  alias AshUi.Expr.Scope
  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Keys
  alias AshUi.Patch.Runtime, as: PatchRuntime
  alias AshUi.Patch.Table
  alias AshUi.RenderTarget.Html
  alias AshUi.Runtime.Rendering
  alias AshUi.Runtime.ResourceInfo

  # ── embedded item fixtures ─────────────────────────────────────────────────

  defmodule Tag do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, primary_key?: true, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule Entry do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:entry_id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:flag, :boolean, allow_nil?: false, default: false, public?: true)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
      attribute(:tags, {:array, Tag}, allow_nil?: false, default: [], public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule DuoRow do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:group, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:slot, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  # ── embedded AshUi children ────────────────────────────────────────────

  defmodule Chip do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(inline(:dc38_chip, [part: :dc38_chip], [text(label)]))
      )
    end
  end

  defmodule CardList do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:rows, {:array, Tag}, allow_nil?: false, default: [], public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          list(:dc38_cards, [part: :dc38_cards], [
            each(rows, :tag, [], [item(:card, [], [text(tag.label)])])
          ])
        )
      )
    end
  end

  # ── pages (one per nesting scenario) ───────────────────────────────────────

  defmodule MatrixPage do
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
      attribute(:title, :string, allow_nil?: false, default: "Inbox", public?: true)
      attribute(:accent, :string, allow_nil?: false, default: "blue", public?: true)
      attribute(:banner, :string, allow_nil?: false, default: "hello", public?: true)
      attribute(:mode, :string, allow_nil?: false, default: "list", public?: true)
      attribute(:selected_id, :string, allow_nil?: false, default: "none", public?: true)

      attribute(:entries, {:array, AshUi.DefectClass.DC38SkeletonMatrixTest.Entry},
        allow_nil?: false,
        default: [],
        public?: true
      )
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])
    end

    calculations do
      calculate(:shout, :string, expr(title <> "!"))

      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [part: :dc38_root], [
            heading(:page_title, [], [text(title)]),
            inline(:accented, [data: %{accent: accent}], [text("a")]),
            render(AshUi.DefectClass.DC38SkeletonMatrixTest.Chip, %{label: banner}),
            if mode == "list" do
              paragraph(:mode_on, [], [text("list mode")])
            else
              paragraph(:mode_off, [], [text("other mode")])
            end,
            list(:rows, [part: :dc38_rows], [
              each(entries, :entry, [], [
                item(:row, [data: %{selected: selected_id == entry.entry_id}], [
                  text(entry.label)
                ])
              ])
            ])
          ])
        )
      )
    end
  end

  defmodule BranchInEachPage do
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

      attribute(:entries, {:array, AshUi.DefectClass.DC38SkeletonMatrixTest.Entry},
        allow_nil?: false,
        default: [],
        public?: true
      )
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
          list(:rows, [part: :dc38_bie], [
            each(entries, :entry, [], [
              item(:row, [], [
                if entry.flag do
                  strong(:on, [], [text(entry.label)])
                else
                  em(:off, [], [text("off")])
                end
              ])
            ])
          ])
        )
      )
    end
  end

  defmodule EachInBranchPage do
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
      attribute(:mode, :string, allow_nil?: false, default: "list", public?: true)

      attribute(:entries, {:array, AshUi.DefectClass.DC38SkeletonMatrixTest.Entry},
        allow_nil?: false,
        default: [],
        public?: true
      )
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
          section(:root, [part: :dc38_eib], [
            if mode == "list" do
              list(:rows, [], [
                each(entries, :entry, [], [item(:row, [], [text(entry.label)])])
              ])
            else
              paragraph(:none, [], [text("no list")])
            end
          ])
        )
      )
    end
  end

  defmodule NestedEachPage do
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

      attribute(:entries, {:array, AshUi.DefectClass.DC38SkeletonMatrixTest.Entry},
        allow_nil?: false,
        default: [],
        public?: true
      )
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
          list(:outer, [part: :dc38_outer], [
            each(entries, :entry, [], [
              item(:outer_row, [], [
                inline(:entry_label, [], [text(entry.label)]),
                list(:inner, [], [
                  each(entry.tags, :tag, [], [
                    # inner item reads BOTH the inner and the OUTER binding
                    item(:inner_row, [], [text(tag.label), text("@"), text(entry.entry_id)])
                  ])
                ])
              ])
            ])
          ])
        )
      )
    end
  end

  defmodule ChildInEachPage do
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

      attribute(:entries, {:array, AshUi.DefectClass.DC38SkeletonMatrixTest.Entry},
        allow_nil?: false,
        default: [],
        public?: true
      )
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
          list(:chips, [part: :dc38_chips], [
            each(entries, :entry, [], [
              item(:chip_row, [], [
                render(AshUi.DefectClass.DC38SkeletonMatrixTest.Chip, %{
                  label: entry.label
                })
              ])
            ])
          ])
        )
      )
    end
  end

  defmodule ShellCardPage do
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
      attribute(:footer, :string, allow_nil?: false, default: "f", public?: true)

      attribute(:card_rows, {:array, AshUi.DefectClass.DC38SkeletonMatrixTest.Tag},
        allow_nil?: false,
        default: [],
        public?: true
      )
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
          section(:shell, [part: :dc38_shell], [
            render(AshUi.DefectClass.DC38SkeletonMatrixTest.CardList, %{rows: card_rows}),
            inline(:footer, [], [text(footer)])
          ])
        )
      )
    end
  end

  defmodule TogglePage do
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
      attribute(:flag, :boolean, allow_nil?: false, default: false, public?: true)
      attribute(:label, :string, allow_nil?: false, default: "shown", public?: true)
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
          section(:root, [part: :dc38_toggle], [
            if flag do
              strong(:yes, [], [text(label)])
            end,
            paragraph(:tail, [], [text("tail")])
          ])
        )
      )
    end
  end

  defmodule KeyedPage do
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

      attribute(:entries, {:array, AshUi.DefectClass.DC38SkeletonMatrixTest.Entry},
        allow_nil?: false,
        default: [],
        public?: true
      )
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
          list(:rows, [part: :dc38_keyed], [
            each(entries, :entry, [key: entry.label], [
              item(:row, [], [text(entry.entry_id)])
            ])
          ])
        )
      )
    end
  end

  defmodule IndexPage do
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

      attribute(:entries, {:array, AshUi.DefectClass.DC38SkeletonMatrixTest.Entry},
        allow_nil?: false,
        default: [],
        public?: true
      )
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
          list(:rows, [part: :dc38_index], [
            each(entries, :entry, [index: :pos], [
              item(:row, [], [text(index(:pos)), text(":"), text(entry.label)])
            ])
          ])
        )
      )
    end
  end

  # ── record builders ────────────────────────────────────────────────────────

  defp seed(resource, attrs) do
    Ash.Seed.seed!(resource, Map.put(attrs, :session_id, Ash.UUID.generate()))
  end

  defp entry(id, opts) do
    struct(Entry, %{
      entry_id: id,
      flag: Keyword.get(opts, :flag, false),
      label: Keyword.get(opts, :label, id),
      tags: Keyword.get(opts, :tags, [])
    })
  end

  defp tag(label), do: struct(Tag, %{label: label})

  # ── full paint from the skeleton (statics + evaluated dynamics) ────────────
  #
  # Unlike the DC-36 helper, the scope THREADS through branch arms and item
  # skeletons: an arm inside an item must still see the item binding, and a
  # nested each must see the outer bindings merged with its own — exactly
  # what the live renderer's scoped opts do.

  defp paint_page(resource, record) do
    table = Compiler.table(resource)

    paint(
      table.skeleton,
      Scope.new(record, %{}, ash_resource_module: resource),
      %{assigns: child_assign_evals(table.slots)}
    )
  end

  defp paint(skeleton, scope, ctx) do
    weave(skeleton.statics, Enum.map(skeleton.dynamics, &paint_dyn(&1, scope, ctx)))
    |> IO.iodata_to_binary()
  end

  defp paint_dyn({:text, _addr, eval}, scope, _ctx) do
    AshUi.Patch.Evaluator.eval(eval, scope)
    |> Html.text_content()
    |> Html.safe_to_iodata()
  end

  defp paint_dyn({:attrs, _addr, eval}, scope, _ctx),
    do: AshUi.Patch.Evaluator.eval(eval, scope)

  defp paint_dyn({:branch, _addr, cond_eval, arms}, scope, ctx) do
    arm =
      if truthy?(AshUi.Patch.Evaluator.eval(cond_eval, scope)),
        do: arms.true,
        else: arms.false

    case arm do
      nil -> ""
      skeleton -> paint(skeleton, scope, ctx)
    end
  end

  defp paint_dyn({:keyed, _addr, items_eval, item}, scope, ctx) do
    AshUi.Patch.Evaluator.eval(items_eval, scope)
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} ->
      item_scope = %{
        scope
        | item_bindings: Map.put(scope.item_bindings, item.as, entry),
          index_bindings: Map.put(scope.index_bindings, item.index, index)
      }

      paint(item.skeleton, item_scope, ctx)
    end)
  end

  defp paint_dyn({:child, _addr, resource, input_eval, _embedded?}, scope, _ctx) do
    assigns = AshUi.Patch.Evaluator.eval(input_eval, scope)

    {:ok, child_record} =
      AshUi.Runtime.ResourceComponentRender.build_resource_component_record(
        resource,
        assigns,
        []
      )

    paint_page(resource, child_record)
  end

  defp weave([s | statics], [d | dynamics]), do: [s, d | weave(statics, dynamics)]
  defp weave([s], []), do: [s]

  defp truthy?(value), do: value not in [nil, false]

  # Child assigns evaluators live in :child slots — including item slots
  # nested inside keyed slots. Addresses are globally unique, so one flat
  # index serves the whole paint.
  defp child_assign_evals(slots) do
    Enum.reduce(slots, %{}, fn
      {_id, %{kind: :child, addr: addr, eval: eval}}, acc ->
        Map.put(acc, addr, eval)

      {_id, %{kind: :keyed_list, meta: %{item_slots: item_slots}}}, acc ->
        Map.merge(acc, child_assign_evals(item_slots))

      _slot, acc ->
        acc
    end)
  end

  # ── the legacy full renderer (the oracle) ──────────────────────────────────

  defp legacy_paint(resource, record, view \\ nil) do
    compiled = ResourceInfo.compiled_resource(resource)
    compiled = if view, do: %{compiled | view: view}, else: compiled

    {:ok, tree} = Rendering.render_tree(compiled, record, %{}, [])
    {:safe, iodata} = Html.render_static(tree)
    IO.iodata_to_binary(iodata)
  end

  defp assert_parity(resource, record) do
    painted = paint_page(resource, record)
    assert painted == legacy_paint(resource, record)
    painted
  end

  # ── gate 1: byte-equality paint across the nesting matrix ─────────────────

  test "scalar + branch + child + keyed page stays byte-aligned across every field change" do
    page = seed(MatrixPage, %{entries: [entry("e1", label: "one"), entry("e2", label: "two")]})

    painted = assert_parity(MatrixPage, page)
    assert painted =~ "Inbox"
    assert painted =~ "hello"
    assert painted =~ "list mode"

    assert_parity(MatrixPage, %{page | title: "Archive"})
    assert_parity(MatrixPage, %{page | accent: "red"})
    assert_parity(MatrixPage, %{page | banner: "updated"})

    flipped = assert_parity(MatrixPage, %{page | mode: "empty"})
    assert flipped =~ "other mode"
    refute flipped =~ "list mode"

    assert_parity(MatrixPage, %{page | selected_id: "e2"})
    assert_parity(MatrixPage, %{page | entries: [entry("e9", label: "nine")]})
    assert_parity(MatrixPage, %{page | entries: []})
  end

  test "branch inside each follows per-item conditions byte-for-byte" do
    page =
      seed(BranchInEachPage, %{
        entries: [
          entry("m1", flag: true, label: "one"),
          entry("m2", label: "two"),
          entry("m3", flag: true, label: "three")
        ]
      })

    painted = assert_parity(BranchInEachPage, page)
    assert painted =~ "one"
    assert painted =~ "three"
    assert painted =~ "off"
    refute painted =~ "two"

    flipped = %{page | entries: Enum.map(page.entries, &%{&1 | flag: not &1.flag})}
    painted = assert_parity(BranchInEachPage, flipped)
    assert painted =~ "two"
    refute painted =~ "one"

    all_off = %{page | entries: Enum.map(page.entries, &%{&1 | flag: false})}
    painted = assert_parity(BranchInEachPage, all_off)
    refute painted =~ "<strong"
  end

  test "each inside a branch arm appears and disappears with the condition" do
    table = Compiler.table(EachInBranchPage)

    # Arm slots are first-class: the arm's keyed slot itself carries the
    # collection dep under its `addr/t|f` address, and the renderer's
    # branch skip gate descends on any changed address under the branch
    # prefix — so an entries change while the list is visible re-renders
    # exactly the keyed slot, never the whole arm.
    {branch_id, branch_slot} = Enum.find(table.slots, fn {_id, s} -> s.kind == :branch end)

    arm_keyed_ids =
      for {id, %{kind: :keyed_list, addr: addr}} <- table.slots,
          String.starts_with?(addr, branch_slot.addr <> "/"),
          do: id

    entries_targets = Map.get(table.propagation, :entries, [])
    assert Enum.any?(arm_keyed_ids, &(&1 in entries_targets))
    refute branch_id in entries_targets

    page =
      seed(EachInBranchPage, %{
        mode: "list",
        entries: [entry("a", label: "alpha"), entry("b", label: "beta")]
      })

    painted = assert_parity(EachInBranchPage, page)
    assert painted =~ "alpha"
    assert painted =~ "beta"

    hidden = assert_parity(EachInBranchPage, %{page | mode: "off"})
    assert hidden =~ "no list"
    refute hidden =~ "alpha"

    back =
      assert_parity(EachInBranchPage, %{
        page
        | mode: "list",
          entries: [entry("c", label: "gamma")]
      })

    assert back =~ "gamma"
    refute back =~ "alpha"
  end

  test "each inside each paints nested collections with merged outer bindings" do
    page =
      seed(NestedEachPage, %{
        entries: [
          entry("e1", label: "first", tags: [tag("t1"), tag("t2")]),
          entry("e2", label: "second", tags: [tag("t3")])
        ]
      })

    painted = assert_parity(NestedEachPage, page)
    # inner item reads the OUTER binding: tag label @ entry id
    assert painted =~ "t1@e1"
    assert painted =~ "t2@e1"
    assert painted =~ "t3@e2"

    grown =
      assert_parity(NestedEachPage, %{
        page
        | entries: [
            entry("e1", label: "first", tags: [tag("t1"), tag("t2"), tag("t9")]),
            entry("e2", label: "second", tags: [])
          ]
      })

    assert grown =~ "t9@e1"
    refute grown =~ "t3@e2"

    assert_parity(NestedEachPage, %{
      page
      | entries: [entry("e2", label: "second", tags: [tag("t3")])]
    })
  end

  test "empty collection -> nonempty -> empty again stays byte-aligned" do
    page = seed(NestedEachPage, %{entries: []})
    empty = assert_parity(NestedEachPage, page)

    filled =
      assert_parity(NestedEachPage, %{
        page
        | entries: [entry("e1", label: "one", tags: [tag("t1")])]
      })

    assert filled =~ "t1@e1"

    empty_again = assert_parity(NestedEachPage, %{page | entries: []})
    assert empty_again == empty
  end

  test "child render inside each builds the child from item-scoped input" do
    page =
      seed(ChildInEachPage, %{
        entries: [entry("e1", label: "alpha"), entry("e2", label: "beta")]
      })

    painted = assert_parity(ChildInEachPage, page)
    assert painted =~ "alpha"
    assert painted =~ "beta"

    relabeled =
      assert_parity(ChildInEachPage, %{
        page
        | entries: [entry("e1", label: "gamma"), entry("e2", label: "beta")]
      })

    assert relabeled =~ "gamma"
    refute relabeled =~ "alpha"

    assert_parity(ChildInEachPage, %{page | entries: [entry("e3", label: "delta")]})
    assert_parity(ChildInEachPage, %{page | entries: []})
  end

  test "each inside a child resource's view stays byte-aligned" do
    page = seed(ShellCardPage, %{card_rows: [tag("r1"), tag("r2")]})

    painted = assert_parity(ShellCardPage, page)
    assert painted =~ "r1"
    assert painted =~ "r2"

    reordered = assert_parity(ShellCardPage, %{page | card_rows: [tag("r2"), tag("r1")]})
    assert reordered =~ "r1"

    emptied = assert_parity(ShellCardPage, %{page | card_rows: []})
    refute emptied =~ "r1"

    assert_parity(ShellCardPage, %{page | card_rows: [tag("r3")], footer: "g"})
  end

  test "branch with only a then-arm flips both ways byte-for-byte" do
    page = seed(TogglePage, %{flag: false, label: "shown"})

    off = assert_parity(TogglePage, page)
    refute off =~ "shown"
    assert off =~ "tail"

    on = assert_parity(TogglePage, %{page | flag: true})
    assert on =~ "shown"

    off_again = assert_parity(TogglePage, %{page | flag: false})
    assert off_again == off
  end

  # ── gate 2: composite primary key entry identity ───────────────────────────

  test "composite primary key yields the full pk tuple; shared first field does not collide" do
    assert Ash.Resource.Info.primary_key(DuoRow) == [:group, :slot]

    row_a = struct(DuoRow, %{group: "g1", slot: "s1", label: "a"})
    row_b = struct(DuoRow, %{group: "g1", slot: "s2", label: "b"})

    assert Keys.entry_key(row_a, 0) == {"g1", "s1"}
    assert Keys.entry_key(row_b, 1) == {"g1", "s2"}

    # same ordinal, same first pk field — keys must still be distinct
    refute Keys.entry_key(row_a, 0) == Keys.entry_key(row_b, 0)
  end

  # ── gate 3: authored key expression ────────────────────────────────────────

  test "authored key: expr compiles key_eval into table and skeleton and overrides pk identity" do
    table = Compiler.table(KeyedPage)

    {_id, keyed_slot} = Enum.find(table.slots, fn {_id, s} -> s.kind == :keyed_list end)
    assert is_function(keyed_slot.meta.key_eval, 1)

    keyed_dyn = Enum.find(table.skeleton.dynamics, &match?({:keyed, _, _, _}, &1))
    assert {:keyed, _addr, _items_eval, item} = keyed_dyn
    assert is_function(item.key_eval, 1)

    page = seed(KeyedPage, %{entries: [entry("e1", label: "alpha")]})
    [e] = page.entries

    scope =
      Scope.new(page, %{}, ash_resource_module: KeyedPage, item_bindings: %{entry: e})

    # authored key wins over the resource pk...
    assert Keys.entry_key(e, 0, item.key_eval, scope) == "alpha"
    # ...which would otherwise key on :entry_id
    assert Keys.entry_key(e, 0, nil, scope) == "e1"

    assert_parity(KeyedPage, page)
  end

  test "compiler retains item-field paths for nested keyed invalidation" do
    table = Compiler.table(NestedEachPage)

    {_id, outer} =
      Enum.find(Table.root_slots(table), fn {_id, slot} -> slot.kind == :keyed_list end)

    outer_item_slots = Table.item_slots(table, outer)

    {_id, label_slot} =
      Enum.find(outer_item_slots, fn {_id, slot} ->
        {:entry, [:label]} in Map.get(slot.meta, :item_dep_paths, [])
      end)

    {_id, inner} =
      Enum.find(outer_item_slots, fn {_id, slot} -> slot.kind == :keyed_list end)

    assert {:entry, [:label]} in label_slot.meta.item_dep_paths
    assert {:entry, [:tags]} in inner.meta.item_dep_paths

    assert Enum.any?(Table.item_slots(table, inner), fn {_id, slot} ->
             {:tag, [:label]} in Map.get(slot.meta, :item_dep_paths, [])
           end)
  end

  # ── gate 4: declared index alias ───────────────────────────────────────────

  test "declared index: alias paints ordinals through index_bindings, not item_bindings" do
    table = Compiler.table(IndexPage)

    assert {:keyed, _addr, _items_eval, item} =
             Enum.find(table.skeleton.dynamics, &match?({:keyed, _, _, _}, &1))

    assert item.as == :entry
    assert item.index == :pos

    page =
      seed(IndexPage, %{
        entries: [entry("x", label: "a"), entry("y", label: "b"), entry("z", label: "c")]
      })

    painted = assert_parity(IndexPage, page)
    assert painted =~ "0:a"
    assert painted =~ "1:b"
    assert painted =~ "2:c"

    # the ordinal resolves ONLY through index_bindings; the first text dyn
    # in document order is text(index(:pos))
    {:text, _a1, index_eval} =
      Enum.find(item.skeleton.dynamics, &match?({:text, _, _}, &1))

    index_scope =
      Scope.new(page, %{}, ash_resource_module: IndexPage, index_bindings: %{pos: 7})

    assert index_eval.(index_scope) == 7

    item_only_scope =
      Scope.new(page, %{}, ash_resource_module: IndexPage, item_bindings: %{pos: 7})

    assert index_eval.(item_only_scope) == nil
  end

  # ── gate 5: changed_addresses precision matrix ─────────────────────────────

  test "changed_addresses reaches exactly the dependent slot addresses per field" do
    table = Compiler.table(MatrixPage)
    slots = Map.values(table.slots)

    title_slot = Enum.find(slots, &(&1.kind == :text and &1.deps == [:title]))

    accent_slot =
      Enum.find(
        slots,
        &(&1.kind == :attrs and &1.deps == [:accent] and not Map.get(&1.meta, :sub_attr?, false))
      )

    # The per-attribute sub-slot (addr@name, owned by the element chunk):
    # the differential renderer gates the individual attr pair on it.
    accent_attr_slot =
      Enum.find(
        slots,
        &(&1.kind == :attrs and &1.deps == [:accent] and Map.get(&1.meta, :sub_attr?, false))
      )

    branch_slot = Enum.find(slots, &(&1.kind == :branch))
    keyed_slot = Enum.find(slots, &(&1.kind == :keyed_list))

    # Chip is embedded and event-free: it INLINES at compile time — no
    # child slot exists; its label ref substituted to the parent's banner,
    # so :banner reaches the inlined TEXT slot directly.
    refute Enum.any?(slots, &(&1.kind == :child)),
           "event-free embedded child should inline, not remain a child slot"

    banner_slot = Enum.find(slots, &(&1.kind == :text and &1.deps == [:banner]))

    assert title_slot, "expected a text slot depending only on :title"
    assert accent_slot, "expected an attrs slot depending only on :accent"
    assert banner_slot, "expected the inlined child text slot depending on :banner"
    assert branch_slot
    assert keyed_slot

    # the keyed slot carries both the collection dep and the item-template
    # parent dep
    assert :entries in keyed_slot.deps
    assert :selected_id in keyed_slot.deps

    page = seed(MatrixPage, %{entries: [entry("e1", label: "one")]})

    # scalar field -> its text slot only
    assert PatchRuntime.changed_addresses(table, page, %{page | title: "Archive"}) ==
             MapSet.new([title_slot.addr])

    # scalar field read only in an element attr -> the element's attrs chunk
    # (owner) plus the per-attribute sub-address that gates the single pair
    assert accent_attr_slot, "expected a per-attribute sub-slot for the accent attr"
    assert accent_attr_slot.addr == accent_slot.addr <> "@data-accent"

    assert PatchRuntime.changed_addresses(table, page, %{page | accent: "red"}) ==
             MapSet.new([accent_slot.addr, accent_attr_slot.addr])

    # child-input field -> the INLINED child dynamic only
    assert PatchRuntime.changed_addresses(table, page, %{page | banner: "updated"}) ==
             MapSet.new([banner_slot.addr])

    # condition field -> the branch slot only
    assert PatchRuntime.changed_addresses(table, page, %{page | mode: "empty"}) ==
             MapSet.new([branch_slot.addr])

    # collection field -> the keyed slot only
    assert PatchRuntime.changed_addresses(table, page, %{page | entries: []}) ==
             MapSet.new([keyed_slot.addr])

    # field read ONLY inside the item template (parent dep) -> the keyed slot
    assert PatchRuntime.changed_addresses(table, page, %{page | selected_id: "e1"}) ==
             MapSet.new([keyed_slot.addr])

    # no-op -> empty set; missing before-image -> :all
    assert PatchRuntime.changed_addresses(table, page, page) == MapSet.new()
    assert PatchRuntime.changed_addresses(table, nil, page) == :all
  end

  # ── gate 6: NotLoaded rules on diff/2 ──────────────────────────────────────

  test "diff treats a calculation NotLoaded on both sides as unchanged, loaded on one side as changed" do
    page = seed(MatrixPage, %{})
    assert %Ash.NotLoaded{} = page.shout

    # NotLoaded on both sides: NOT changed
    diffed = PatchRuntime.diff(page, %{page | title: "X"})
    assert :title in diffed.fields
    refute :shout in diffed.fields

    # loaded on one side only: changed (both directions)
    assert :shout in PatchRuntime.diff(page, %{page | shout: "X!"}).fields
    assert :shout in PatchRuntime.diff(%{page | shout: "X!"}, page).fields

    # loaded on both sides, different value: changed
    assert :shout in PatchRuntime.diff(%{page | shout: "A!"}, %{page | shout: "B!"}).fields

    # loaded on both sides, same value: NOT changed
    refute :shout in PatchRuntime.diff(%{page | shout: "A!"}, %{page | shout: "A!"}).fields

    # a full no-op diffs to no fields at all
    assert PatchRuntime.diff(page, page).fields == []
  end
end
