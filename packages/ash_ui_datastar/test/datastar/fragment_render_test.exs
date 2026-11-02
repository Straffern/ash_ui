defmodule AshUi.Datastar.FragmentRenderTest do
  use ExUnit.Case, async: false

  alias AshUi.Datastar.{FragmentRender, RenderTarget, SSE}
  alias AshUi.Patch.{Compiler, Runtime}
  alias AshUi.Phoenix.LiveRender
  alias Phoenix.LiveView.Diff

  defmodule Row do
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
      attribute(:done?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule Nest10 do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(box(:leaf, [], [text(label)]))
      )
    end
  end

  defmodule Nest9 do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:level9, [], [
            text(label),
            render(AshUi.Datastar.FragmentRenderTest.Nest10, %{label: label <> "."})
          ])
        )
      )
    end
  end

  defmodule Nest8 do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:level8, [], [
            text(label),
            render(AshUi.Datastar.FragmentRenderTest.Nest9, %{label: label <> "."})
          ])
        )
      )
    end
  end

  defmodule Nest7 do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:level7, [], [
            text(label),
            render(AshUi.Datastar.FragmentRenderTest.Nest8, %{label: label <> "."})
          ])
        )
      )
    end
  end

  defmodule Nest6 do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:level6, [], [
            text(label),
            render(AshUi.Datastar.FragmentRenderTest.Nest7, %{label: label <> "."})
          ])
        )
      )
    end
  end

  defmodule Nest5 do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:level5, [], [
            text(label),
            render(AshUi.Datastar.FragmentRenderTest.Nest6, %{label: label <> "."})
          ])
        )
      )
    end
  end

  defmodule Nest4 do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:level4, [], [
            text(label),
            render(AshUi.Datastar.FragmentRenderTest.Nest5, %{label: label <> "."})
          ])
        )
      )
    end
  end

  defmodule Nest3 do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:level3, [], [
            text(label),
            render(AshUi.Datastar.FragmentRenderTest.Nest4, %{label: label <> "."})
          ])
        )
      )
    end
  end

  defmodule Nest2 do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:level2, [], [
            text(label),
            render(AshUi.Datastar.FragmentRenderTest.Nest3, %{label: label <> "."})
          ])
        )
      )
    end
  end

  defmodule Nest1 do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:level1, [], [
            text(label),
            render(AshUi.Datastar.FragmentRenderTest.Nest2, %{label: label <> "."})
          ])
        )
      )
    end
  end

  defmodule DeepPage do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:deep_label, :string, allow_nil?: false, default: "root", public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:deep_root, [], [
            render(AshUi.Datastar.FragmentRenderTest.Nest1, %{label: deep_label}),
            list(:deep_rows, [], [
              each(rows, :row, [key: row.id], [
                item(:deep_row, [], [text(row.label)])
              ])
            ])
          ])
        )
      )
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Group do
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
      attribute(:open?, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(false)
    end

    ash_ui do
      stylesheets(["test/support/assets/datastar_test.css"])
    end

    routes do
      route("/datastar")
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:title, :string, allow_nil?: false, default: "Inbox", public?: true)
      attribute(:tone, :string, allow_nil?: false, default: "calm", public?: true)
      attribute(:selected, :string, allow_nil?: false, default: "none", public?: true)
      attribute(:show?, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:branch_open?, :boolean, allow_nil?: false, default: false, public?: true)
      attribute(:other, :string, allow_nil?: false, default: "ignored", public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create(:mount)

      update :select do
        require_atomic?(false)
        argument(:id, :string, allow_nil?: false)
        change(set_attribute(:selected, arg(:id)))
      end

      update :set_title do
        accept([:title])
        validate(string_length(:title, min: 3))
      end

      update :toggle do
        require_atomic?(false)

        change(fn changeset, _ ->
          Ash.Changeset.change_attribute(changeset, :show?, !changeset.data.show?)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [part: :ds_root], [
            heading(:title, [], [text(title)]),
            box(:tone, [data: %{tone: tone}], [text("tone")]),
            input(
              :title_input,
              type: :text,
              name: :title,
              value: title,
              on_input: :set_title
            ),
            button(:toggle, [type: :button, on_click: :toggle], [text("toggle")]),
            if show? do
              paragraph(:shown, [state: [open: branch_open?]], [text("shown")])
            else
              paragraph(:hidden, [], [text("hidden")])
            end,
            inline(:selected, [], [text(selected)]),
            list(:rows, [part: :ds_rows], [
              each(rows, :row, [], [
                item(
                  :entry,
                  [
                    part: :ds_row,
                    data: %{done: row.done?},
                    on_click: :select,
                    action_input: %{id: row.id}
                  ],
                  [text(row.label)]
                )
              ])
            ])
          ])
        )
      )
    end
  end

  defmodule Child do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "child", public?: true)
      attribute(:open?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    actions do
      defaults(create: :*, update: :*)

      update :toggle do
        require_atomic?(false)

        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :open?, !changeset.data.open?)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:child, [data: %{open: open?}], [
            button(:toggle, [type: :button, on_click: :toggle], [text(label)])
          ])
        )
      )
    end
  end

  defmodule ChildPage do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(false)
    end

    attributes do
      attribute(:session_id, :uuid, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:label, :string, allow_nil?: false, default: "child", public?: true)
      attribute(:open?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create(:mount)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(render(Child, %{label: label, open?: open?}))
      )
    end
  end

  defmodule NestedPage do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(false)
    end

    attributes do
      attribute(:session_id, :uuid, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:groups, {:array, Group}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create(:mount)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:nested_root, [], [
            list(:groups, [], [
              each(groups, :group, [], [
                item(:group_entry, [], [
                  paragraph(:group_label, [], [text("group")]),
                  list(:group_rows, [], [
                    each(group.rows, :nested_row, [], [
                      item(
                        :nested_entry,
                        [data: %{done: nested_row.done?}],
                        [text(nested_row.label)]
                      )
                    ])
                  ])
                ])
              ])
            ])
          ])
        )
      )

      calculate(
        :coalesced_view,
        AshUi.Type.RenderTree,
        expr(
          section(:coalesced_root, [], [
            list(:coalesced_groups, [], [
              each(groups, :group, [], [
                item(:coalesced_group, [data: %{group: group.id}], [
                  list(:coalesced_rows, [], [
                    each(group.rows, :nested_row, [], [
                      item(:coalesced_entry, [], [text(nested_row.label)])
                    ])
                  ])
                ])
              ])
            ])
          ])
        )
      )

      calculate(
        :branch_view,
        AshUi.Type.RenderTree,
        expr(
          section(:branch_root, [], [
            list(:branch_groups, [], [
              each(groups, :group, [], [
                item(:branch_group, [], [
                  if group.open? do
                    paragraph(:group_label, [], [text(group.label)])
                  else
                    paragraph(:closed_group, [], [text("closed")])
                  end
                ])
              ])
            ])
          ])
        )
      )
    end
  end

  def table, do: Compiler.table(Page, target: RenderTarget)

  def page(attrs \\ %{}) do
    struct(
      Page,
      Map.merge(
        %{
          session_id: Ash.UUID.generate(),
          rows: [row("r1", "one"), row("r2", "two"), row("r3", "three")]
        },
        attrs
      )
    )
  end

  def row(id, label, done? \\ false), do: struct(Row, %{id: id, label: label, done?: done?})

  def group(id, label, rows, open? \\ true),
    do: struct(Group, %{id: id, label: label, rows: rows, open?: open?})

  test "byte oracle equals Rendering.render_tree through Html for branch states and keyed mutations" do
    for record <- [
          page(),
          page(%{show?: false}),
          page(%{rows: [row("r3", "three"), row("r1", "ONE"), row("r4", "four")]})
        ] do
      compiled = AshUi.Runtime.ResourceInfo.compiled_resource(Page)

      {:ok, tree} =
        AshUi.Runtime.Rendering.render_tree(compiled, record, %{}, target: RenderTarget)

      {:safe, expected} = AshUi.RenderTarget.Html.render_static(tree, target: RenderTarget)
      assert FragmentRender.full_render(record, table()) == IO.iodata_to_binary(expected)
    end
  end

  describe "oracle equivalence at 10-level component nesting" do
    defp deep_table do
      Compiler.table(DeepPage, target: AshUi.Datastar.RenderTarget)
    end

    defp deep_build(record, changed, table) do
      AshUi.Render.build(record, changed,
        table: table,
        target: AshUi.Datastar.RenderTarget
      )
    end

    defp both_engines(record, changed, table, {core_prints, lv_prints, lv_components}) do
      {core_diff, core_prints} =
        AshUi.Diff.render(deep_build(record, changed, table), core_prints)

      {lv_diff, lv_prints, lv_components} =
        Diff.render(
          %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}},
          deep_build(record, changed, table) |> LiveRender.to_live(),
          lv_prints,
          lv_components
        )

      assert core_diff == lv_diff
      {core_diff, {core_prints, lv_prints, lv_components}}
    end

    defp fresh_state do
      {AshUi.Diff.new_fingerprints(), Diff.new_fingerprints(), Diff.new_components()}
    end

    test "mount renders ten nested boundaries identically in both engines" do
      table = deep_table()
      record = %DeepPage{session_id: Ash.UUID.generate(), deep_label: "root", rows: []}

      {diff, _state} = both_engines(record, :all, table, fresh_state())

      # the leaf carries the label routed through all ten inputs
      html = diff |> Jason.encode!()
      assert html =~ "root........."
    end

    test "a leaf-reaching update stays minimal and identical at depth ten" do
      table = deep_table()
      old = %DeepPage{session_id: Ash.UUID.generate(), deep_label: "root", rows: []}
      {_mount, state} = both_engines(old, :all, table, fresh_state())

      new = %{old | deep_label: "changed"}
      changed = AshUi.Patch.Runtime.changed_addresses(table, old, new)

      {diff, _state} = both_engines(new, changed, table, state)

      # not a full re-render: statics stay retained at the root
      refute Map.has_key?(diff, :s)
      assert Jason.encode!(diff) =~ "changed........."
    end

    test "a no-op update produces the unchanged diff in both engines" do
      table = deep_table()
      record = %DeepPage{session_id: Ash.UUID.generate(), deep_label: "root", rows: []}
      {_mount, state} = both_engines(record, :all, table, fresh_state())

      {diff, _state} = both_engines(record, MapSet.new(), table, state)

      assert diff == %{}
    end

    test "a root fingerprint mismatch resets retained state identically" do
      table = deep_table()
      record = %DeepPage{session_id: Ash.UUID.generate(), deep_label: "root", rows: []}
      {mount_diff, _state} = both_engines(record, :all, table, fresh_state())

      # feed prints from a DIFFERENT root: both engines must reset and
      # re-render fully
      other_prints = {:erlang.phash2(:other_root), %{}}

      {core_diff, _} =
        AshUi.Diff.render(deep_build(record, :all, table), other_prints)

      {lv_diff, _, _} =
        Diff.render(
          %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}},
          deep_build(record, :all, table) |> LiveRender.to_live(),
          other_prints,
          Diff.new_components()
        )

      assert core_diff == lv_diff
      assert core_diff == mount_diff
    end

    test "empty -> populated -> empty comprehensions transition identically" do
      table = deep_table()
      sid = Ash.UUID.generate()

      states = [
        %DeepPage{session_id: sid, deep_label: "root", rows: []},
        %DeepPage{session_id: sid, deep_label: "root", rows: [row("a", "one")]},
        %DeepPage{
          session_id: sid,
          deep_label: "root",
          rows: [row("b", "two"), row("a", "ONE"), row("c", "three")]
        },
        %DeepPage{session_id: sid, deep_label: "root", rows: [row("c", "three")]},
        %DeepPage{session_id: sid, deep_label: "root", rows: []},
        %DeepPage{session_id: sid, deep_label: "root", rows: [row("d", "four")]}
      ]

      Enum.reduce(states, {hd(states), :mount, fresh_state()}, fn next, {prev, phase, state} ->
        changed =
          if phase == :mount,
            do: :all,
            else: AshUi.Patch.Runtime.changed_addresses(table, prev, next)

        {_diff, state} = both_engines(next, changed, table, state)
        {next, :update, state}
      end)
    end

    test "a combined deep-label and keyed-row mutation sequence stays identical" do
      table = deep_table()
      sid = Ash.UUID.generate()
      base = %DeepPage{session_id: sid, deep_label: "root", rows: [row("r1", "one")]}

      states =
        Enum.flat_map(0..40, fn i ->
          [
            %{base | deep_label: "d#{i}"},
            %{base | deep_label: "d#{i}", rows: [row("s#{i}", "l#{i}"), row("r1", "one")]},
            %{
              base
              | deep_label: "d#{i}",
                rows: Enum.reverse([row("s#{i}", "l#{i}"), row("r1", "x#{i}")])
            }
          ]
        end)

      Enum.reduce(states, {base, :mount, fresh_state()}, fn next, {prev, phase, state} ->
        changed =
          if phase == :mount,
            do: :all,
            else: AshUi.Patch.Runtime.changed_addresses(table, prev, next)

        {_diff, state} = both_engines(next, changed, table, state)
        {next, :update, state}
      end)
    end
  end

  test "algebra structs mirror the native LiveView structs field-for-field" do
    assert Map.keys(%AshUi.Rendered{}) |> Enum.sort() ==
             Map.keys(%Phoenix.LiveView.Rendered{}) |> Enum.sort()

    assert Map.keys(%AshUi.Comprehension{}) |> Enum.sort() ==
             Map.keys(%Phoenix.LiveView.Comprehension{}) |> Enum.sort()
  end

  test "a long mutation sequence produces identical diffs in both engines" do
    live_table = Compiler.table(Page, target: AshUi.Datastar.RenderTarget)
    rows = fn count -> Enum.map(1..count//1, &row("r#{&1}", "label#{&1}")) end
    base = %Page{session_id: Ash.UUID.generate(), title: "Inbox", tone: "calm", rows: rows.(3)}

    # scalar flips, branch flips, keyed insert/move/remove/update, nested
    # churn — every diff must match Phoenix.LiveView.Diff exactly
    states =
      Enum.flat_map(0..60, fn i ->
        [
          %{base | title: "t#{i}"},
          %{base | tone: Enum.at(~w(calm loud), rem(i, 2)), title: "t#{i}"},
          %{base | rows: rows.(rem(i, 5)), title: "t#{i}"},
          %{base | rows: Enum.reverse(rows.(rem(i, 4) + 1)), title: "t#{i}"},
          %{
            base
            | rows: List.update_at(rows.(3), rem(i, 3), &%{&1 | label: "l#{i}"}),
              title: "t#{i}"
          }
        ]
      end)

    build = fn record, changed ->
      AshUi.Render.build(record, changed,
        table: live_table,
        target: AshUi.Datastar.RenderTarget
      )
    end

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    Enum.reduce(
      states,
      {hd(states), AshUi.Diff.new_fingerprints(), Diff.new_fingerprints(),
       Diff.new_components(), 0},
      fn next, {prev, core_prints, lv_prints, lv_components, step} ->
        changed = AshUi.Patch.Runtime.changed_addresses(live_table, prev, next)

        {core_diff, core_prints} =
          AshUi.Diff.render(build.(next, changed), core_prints)

        {lv_diff, lv_prints, lv_components} =
          Diff.render(
            socket,
            build.(next, changed) |> LiveRender.to_live(),
            lv_prints,
            lv_components
          )

        assert core_diff == lv_diff, "diff diverged at step #{step}: #{inspect(next)}"

        {next, core_prints, lv_prints, lv_components, step + 1}
      end
    )
  end

  test "mount and updates retain the exact native LiveView diff state" do
    old = page()
    updated = %{old | selected: "Changed"}
    live_table = Compiler.table(Page, target: AshUi.Datastar.RenderTarget)

    {_html, state} = FragmentRender.initial_render(old, table())

    {mount_diff, mount_prints, _mount_components} =
      Diff.render(
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}},
        old
        |> AshUi.Render.build(:all,
          table: live_table,
          target: AshUi.Datastar.RenderTarget
        )
        |> LiveRender.to_live(),
        Diff.new_fingerprints(),
        Diff.new_components()
      )

    assert state.diff == mount_diff
    assert state.prints == mount_prints

    changed = Runtime.changed_addresses(table(), old, updated)

    {expected_diff, expected_prints, _expected_components} =
      Diff.render(
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}},
        updated
        |> AshUi.Render.build(changed,
          table: live_table,
          target: AshUi.Datastar.RenderTarget
        )
        |> LiveRender.to_live(),
        mount_prints,
        Diff.new_components()
      )

    {events, state} = FragmentRender.render(updated, changed, [], table(), state, [])

    assert events != []
    assert state.diff == expected_diff
    assert state.prints == expected_prints
  end

  test "nested resource diffs project the changed child element instead of the page root" do
    old = struct(ChildPage, %{session_id: Ash.UUID.generate(), label: "child", open?: false})
    updated = %{old | open?: true}
    table = Compiler.table(ChildPage, target: RenderTarget)

    assert [event] = FragmentRender.patch(old, updated, table)
    assert event.meta.address == "v"
    assert event.meta.region == "v|v"

    wire = SSE.encode(event)
    assert wire =~ "selector #" <> RenderTarget.dom_id("v", ["v"])
    refute wire =~ "selector #" <> RenderTarget.dom_id("v") <> "\n"
    assert wire =~ ~r/<section data-open(?: |>)/
  end

  test "nested keyed diffs patch the changed inner entry, not its outer keyed parent" do
    old =
      struct(NestedPage, %{
        session_id: Ash.UUID.generate(),
        groups: [
          group("g1", "first", [row("r1", "one"), row("r2", "two")]),
          group("g2", "second", [row("r3", "three")])
        ]
      })

    [first, second] = old.groups

    updated =
      %{
        old
        | groups: [%{first | rows: List.update_at(first.rows, 1, &%{&1 | label: "TWO"})}, second]
      }

    table = Compiler.table(NestedPage, target: RenderTarget)
    {_html, state} = FragmentRender.initial_render(old, table)
    changed = Runtime.changed_addresses(table, old, updated)

    assert {[event], state} = FragmentRender.render(updated, changed, [], table, state, [])
    assert state.diff != %{}
    assert event.meta == %{key: "r2", operation: :morph, region: event.meta.region}

    wire = SSE.encode(event)
    assert wire =~ ~s(part="nested_entry")
    assert wire =~ "TWO"
    refute wire =~ ~s(part="group_entry")
    refute wire =~ "three"
  end

  test "a nested-only change keeps its minimal region through static outer wrappers" do
    old =
      struct(NestedPage, %{
        session_id: Ash.UUID.generate(),
        groups: [group("g1", "first", [row("r1", "one"), row("r2", "two")])]
      })

    [first] = old.groups

    updated =
      %{
        old
        | groups: [
            %{first | rows: List.update_at(first.rows, 1, &%{&1 | label: "TWO"})}
          ]
      }

    table = Compiler.table(NestedPage, :coalesced_view, target: RenderTarget)
    {_html, state} = FragmentRender.initial_render(old, table)
    changed = Runtime.changed_addresses(table, old, updated)

    assert {[event], state} = FragmentRender.render(updated, changed, [], table, state, [])
    assert state.diff != %{}
    assert event.meta.key == "r2"

    wire = SSE.encode(event)
    assert wire =~ ~s(part="coalesced_entry")
    refute wire =~ ~s(part="coalesced_group")
    refute wire =~ "one"
    assert wire =~ "TWO"
  end

  test "a same-arm branch change nested in a keyed entry patches the branch element" do
    old =
      struct(NestedPage, %{
        session_id: Ash.UUID.generate(),
        groups: [group("g1", "first", [])]
      })

    [first] = old.groups
    updated = %{old | groups: [%{first | label: "FIRST"}]}
    table = Compiler.table(NestedPage, :branch_view, target: RenderTarget)

    {_html, state} = FragmentRender.initial_render(old, table)
    changed = Runtime.changed_addresses(table, old, updated)
    {[event], state} = FragmentRender.render(updated, changed, [], table, state, [])
    assert state.diff != %{}

    wire = SSE.encode(event)
    assert wire =~ ~s(part="group_label")
    assert wire =~ "FIRST"
    refute wire =~ ~s(part="branch_group")
  end

  test "a nested branch flip morphs only the arm root, on its mount-rendered stable id" do
    old =
      struct(NestedPage, %{
        session_id: Ash.UUID.generate(),
        groups: [group("g1", "first", [])]
      })

    [first] = old.groups
    updated = %{old | groups: [%{first | open?: false}]}
    table = Compiler.table(NestedPage, :branch_view, target: RenderTarget)

    mount_html = FragmentRender.full_render(old, table)
    assert [event] = FragmentRender.patch(old, updated, table)

    wire = SSE.encode(event)
    # both arms share one boundary id: the flip is an in-place morph of the
    # arm root, never a re-render of the containing entry
    assert [_, selector_id] = Regex.run(~r/data: selector #(\S+)/, wire)
    assert mount_html =~ ~s(id="#{selector_id}")
    assert wire =~ ~s(part="closed_group")
    refute wire =~ ~s(part="branch_group")
    refute wire =~ ~s(part="group_label")
  end

  test "mixed keyed edits project the exact LiveView keyed result without a row diff" do
    old = page()

    updated =
      %{old | rows: [row("r3", "THREE"), row("r1", "one"), row("r4", "four")]}

    {_html, state} = FragmentRender.initial_render(old, table())
    changed = Runtime.changed_addresses(table(), old, updated)
    {events, state} = FragmentRender.render(updated, changed, [], table(), state, [])

    assert %{6 => %{k: live_keyed}} = state.diff
    assert live_keyed[:kc] == 3

    # content changes morph in place; position changes ride the ONE
    # content-free reorder script; nothing re-renders for a pure move
    assert MapSet.new(
             Enum.map(
               events,
               &{&1.meta.operation, Map.get(&1.meta, :key, Map.get(&1.meta, :keys))}
             )
           ) ==
             MapSet.new([
               {:remove, "r2"},
               {:morph, "r3"},
               {:insert, "r4"},
               {:reorder, ["r3", "r1", "r4"]}
             ])
  end

  test "duplicate keyed identities fail in LiveView before SSE projection" do
    old = page()
    duplicate = %{old | rows: [row("same", "one"), row("same", "two")]}
    {_html, state} = FragmentRender.initial_render(old, table())
    changed = Runtime.changed_addresses(table(), old, duplicate)

    assert_raise RuntimeError, ~r/found duplicate key/, fn ->
      FragmentRender.render(duplicate, changed, [], table(), state, [])
    end
  end

  test "scalar text change emits exactly the owning region" do
    old = page()
    events = FragmentRender.patch(old, %{old | selected: "Changed"}, table())
    assert [%SSE.Event{} = event] = events
    assert SSE.encode(event) =~ "Changed"
    refute SSE.encode(event) =~ "three"
  end

  test "attrs-only change emits the owning element" do
    old = page()

    assert [%SSE.Event{} = event] =
             FragmentRender.patch(old, %{old | tone: "loud"}, table())

    assert SSE.encode(event) =~ "data-tone=\"loud\""
  end

  test "attrs-only change inside an unchanged branch emits the owning element" do
    old = page()

    assert [%SSE.Event{} = event] =
             FragmentRender.patch(old, %{old | branch_open?: true}, table())

    assert SSE.encode(event) =~ "aria-expanded=\"true\""
    assert SSE.encode(event) =~ "part=\"shown\""
  end

  test "one changed row in a keyed collection emits exactly that entry" do
    old = page()
    rows = List.update_at(old.rows, 1, &%{&1 | label: "TWO"})

    assert [%SSE.Event{meta: %{key: "r2", operation: :morph}} = event] =
             FragmentRender.patch(old, %{old | rows: rows}, table())

    wire = SSE.encode(event)
    assert wire =~ "TWO"
    refute wire =~ "one"
    refute wire =~ "three"
  end

  test "insert, remove, and reorder stay entry-scoped" do
    old = page()

    assert [%SSE.Event{meta: %{key: "r4", operation: :insert}}] =
             FragmentRender.patch(old, %{old | rows: old.rows ++ [row("r4", "four")]}, table())

    assert [%SSE.Event{meta: %{key: "r2", operation: :remove}}] =
             FragmentRender.patch(
               old,
               %{old | rows: [Enum.at(old.rows, 0), Enum.at(old.rows, 2)]},
               table()
             )

    # a pure reorder is ONE content-free script over the final key order
    assert [%SSE.Event{meta: %{operation: :reorder, keys: ["r3", "r2", "r1"]}} = event] =
             FragmentRender.patch(old, %{old | rows: Enum.reverse(old.rows)}, table())

    wire = SSE.encode(event)
    refute wire =~ "one"
    refute wire =~ "two"
    refute wire =~ "three"
  end

  test "a single keyed move keeps the longest stable subsequence in place" do
    rows = Enum.map(1..10, &row("r#{&1}", "row #{&1}"))
    old = page(%{rows: rows})
    updated = %{old | rows: [List.last(rows) | Enum.drop(rows, -1)]}

    assert [%SSE.Event{meta: %{operation: :reorder}} = event] =
             FragmentRender.patch(old, updated, table())

    wire = SSE.encode(event)
    assert wire =~ "insertBefore"
    refute wire =~ "appendChild"

    # container + moved entry + its right-hand anchor; the other nine entry
    # ids do not ride the wire and are not touched by the browser script.
    assert length(Regex.scan(~r/bp-[A-Za-z0-9_-]{10}/, wire)) == 3
  end

  test "branch flip emits one arm fragment while unrelated and no-op changes emit nothing" do
    old = page()
    assert [%SSE.Event{} = event] = FragmentRender.patch(old, %{old | show?: false}, table())
    assert SSE.encode(event) =~ "hidden"
    refute SSE.encode(event) =~ "shown"
    assert FragmentRender.patch(old, %{old | other: "still ignored"}, table()) == []
    assert FragmentRender.patch(old, old, table()) == []
  end

  @tag :bench
  test "one row in 10k stays under the byte and wall budget" do
    rows = for i <- 1..10_000, do: row("r#{i}", "label #{i}")
    old = page(%{rows: rows})
    updated = %{old | rows: List.update_at(rows, 5_000, &%{&1 | label: "CHANGED"})}

    {us, events} = :timer.tc(fn -> FragmentRender.patch(old, updated, table()) end)
    bytes = events |> SSE.encode() |> byte_size()
    IO.puts("\n| Datastar 10k one-row patch | #{div(us, 1000)}ms | #{bytes}B |")

    assert length(events) == 1
    assert div(us, 1000) < 1_000
    assert bytes < 2_048
  end
end
