defmodule AshUi.Phoenix.LvWireMatrixTest do
  @moduledoc """
  LiveView wire-protocol matrix: every operation and nesting type through the
  REAL LiveView diff engine.

    server: AshUi.Phoenix.LiveRender.build + Phoenix.LiveView.Diff.render
    change source: AshUi.Patch.Runtime.changed_addresses (NO tree diffing)
    client: Phoenix.LiveViewTest.Diff.merge_diff (LiveView's client simulation)
    oracle: full render through the Phoenix target

  Gates:
   1. scalar text change ships exactly one dynamic
   2. attr-chunk change ships only that chunk
   3. branch flips ship arm statics; active-arm dep re-renders the arm;
      inactive-arm dep coarseness measured + documented
   4. keyed rows: content change / remove / insert / reorder / clear wire shapes
   5. declared index: pure reorder re-renders moved rows with new ordinals
   6. parent dep in rows ships per-entry updates, never container replacement
   7. child render(Resource, input) re-renders only on its input change
   8. nested: each-in-branch, branch-in-each, each-in-each
   9. no-op after EVERY step ships an empty diff (asserted inside step/5)
  10. 50 randomized action steps stay byte-identical to fresh full renders

  After EVERY step, paint(client) must be byte-identical to a fresh legacy
  full render of the updated record.
  """
  use ExUnit.Case, async: false

  alias AshUi.Patch.Runtime, as: PatchRuntime
  alias AshUi.Phoenix.LiveRender
  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveViewTest.Diff, as: Client

  # ── shared embedded row ─────────────────────────────────────────────────────

  defmodule Row do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:message_id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
      attribute(:flag?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  # ── the rich matrix page (gates 1, 2, 3, 4, 6, 10) ──────────────────────────
  #
  # Dynamic layout (document order):
  #   0 = text(title)
  #   1 = attrs chunk of the status box (dynamic data-status)
  #   2 = branch (flag ? on-arm : off-arm; arms have DIFFERENT statics)
  #   3 = keyed rows (item reads parent scalar selected_id)

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
      attribute(:status, :string, allow_nil?: false, default: "idle", public?: true)
      attribute(:flag, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:active_note, :string, allow_nil?: false, default: "alpha", public?: true)
      attribute(:fallback_note, :string, allow_nil?: false, default: "beta", public?: true)
      attribute(:selected_id, :string, public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :retitle do
        require_atomic?(false)
        argument(:title, :string, allow_nil?: false)
        change(set_attribute(:title, arg(:title)))
      end

      update :set_status do
        require_atomic?(false)
        argument(:status, :string, allow_nil?: false)
        change(set_attribute(:status, arg(:status)))
      end

      update :set_flag do
        require_atomic?(false)
        argument(:flag, :boolean, allow_nil?: false)
        change(set_attribute(:flag, arg(:flag)))
      end

      update :set_active_note do
        require_atomic?(false)
        argument(:note, :string, allow_nil?: false)
        change(set_attribute(:active_note, arg(:note)))
      end

      update :set_fallback_note do
        require_atomic?(false)
        argument(:note, :string, allow_nil?: false)
        change(set_attribute(:fallback_note, arg(:note)))
      end

      update :select do
        require_atomic?(false)
        argument(:selected_id, :string, allow_nil?: true)
        change(set_attribute(:selected_id, arg(:selected_id)))
      end

      update :put_rows do
        require_atomic?(false)
        argument(:rows, {:array, Row}, allow_nil?: false)
        change(set_attribute(:rows, arg(:rows)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section([], [
            heading([], [text(title)]),
            box([], [attr(:"data-status", status), text("status-box")]),
            if flag do
              box([], [text("on: "), text(active_note)])
            else
              paragraph([], [text("off: "), text(fallback_note)])
            end,
            list([], [
              each(rows, :row, [], [
                item([], [attr(:"data-sel", row.message_id == selected_id), text(row.label)])
              ])
            ])
          ])
        )
      )
    end
  end

  defmodule ConditionalControlPage do
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
      attribute(:show_page, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:editor_open, :boolean, allow_nil?: false, default: false, public?: true)
      attribute(:editor_text, :string, allow_nil?: false, default: "", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :open_editor do
        require_atomic?(false)
        argument(:editor_text, :string, allow_nil?: false)
        change(set_attribute(:editor_open, true))
        change(set_attribute(:editor_text, arg(:editor_text)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section([], [
            if show_page do
              box([], [
                dialog([open: editor_open], [
                  textarea(name: :editor_text, value: editor_text)
                ]),
                paragraph([], [text("stable sibling")])
              ])
            else
              text("unavailable")
            end
          ])
        )
      )
    end
  end

  # ── declared index page (gate 5) ────────────────────────────────────────────
  # Dynamics: 0 = keyed; item dynamics: 0 = ordinal, 1 = label.

  defmodule OrdinalPage do
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
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :put_rows do
        require_atomic?(false)
        argument(:rows, {:array, Row}, allow_nil?: false)
        change(set_attribute(:rows, arg(:rows)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          list([], [
            each(rows, :row, [index: :pos], [
              item([], [text(index(:pos)), text(": "), text(row.label)])
            ])
          ])
        )
      )
    end
  end

  # A keyed entry with two top-level elements is intentionally not eligible
  # for LiveView root tracking: no single DOM node can own its magic id.
  defmodule MultiRootKeyedPage do
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
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
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
          list([], [
            each(rows, :row, [], [
              item([], [text(row.label)]),
              item([], [text(row.message_id)])
            ])
          ])
        )
      )
    end
  end

  defmodule ConditionalSiblingKeyedPage do
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
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
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
          list([], [
            each(rows, :row, [], [
              if row.flag? do
                item([], [text("new")])
              else
                nothing()
              end,
              item([], [text(row.label)])
            ])
          ])
        )
      )
    end
  end

  defmodule RootTrackedChild do
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

      update :pick do
        require_atomic?(false)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(button([on_click: :pick], [text(label)]))
      )
    end
  end

  defmodule RootTrackedChildHost do
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
      attribute(:label, :string, allow_nil?: false, default: "child", public?: true)
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
        expr(section([], [render(RootTrackedChild, %{label: label})]))
      )
    end
  end

  # ── child render (gate 7) ───────────────────────────────────────────────────
  # Dynamics: 0 = text(other), 1 = child render(ChildCard, %{label: card_label}).

  defmodule ChildCard do
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
        expr(box([], [text("card: "), text(label)]))
      )
    end
  end

  defmodule ChildHostPage do
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
      attribute(:other, :string, allow_nil?: false, default: "o1", public?: true)
      attribute(:card_label, :string, allow_nil?: false, default: "c1", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :set_other do
        require_atomic?(false)
        argument(:other, :string, allow_nil?: false)
        change(set_attribute(:other, arg(:other)))
      end

      update :set_card_label do
        require_atomic?(false)
        argument(:card_label, :string, allow_nil?: false)
        change(set_attribute(:card_label, arg(:card_label)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section([], [
            box([], [text(other)]),
            render(ChildCard, %{label: card_label})
          ])
        )
      )
    end
  end

  defmodule FragmentCard do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:content, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(box([], [text("fragment: "), content]))
      )
    end
  end

  defmodule FragmentHostPage do
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
      attribute(:other, :string, allow_nil?: false, default: "o1", public?: true)
      attribute(:fragment_label, :string, allow_nil?: false, default: "f1", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :set_fragment_label do
        require_atomic?(false)
        argument(:fragment_label, :string, allow_nil?: false)
        change(set_attribute(:fragment_label, arg(:fragment_label)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section([], [
            text(other),
            render(FragmentCard, %{content: strong([], [text(fragment_label)])})
          ])
        )
      )
    end
  end

  # Gate 7b fixtures: an embedded child whose element carries an event
  # binding — binding keys cross its boundary, so it must NOT inline; the
  # runtime child boundary stays on the wire.

  defmodule EventCard do
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
        expr(button(:poke, [type: :button, on_click: :poke], [text("ecard: "), text(label)]))
      )
    end
  end

  defmodule EventChildHostPage do
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
      attribute(:other, :string, allow_nil?: false, default: "o1", public?: true)
      attribute(:card_label, :string, allow_nil?: false, default: "e1", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :set_other do
        require_atomic?(false)
        argument(:other, :string, allow_nil?: false)
        change(set_attribute(:other, arg(:other)))
      end

      update :set_card_label do
        require_atomic?(false)
        argument(:card_label, :string, allow_nil?: false)
        change(set_attribute(:card_label, arg(:card_label)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section([], [
            box([], [text(other)]),
            render(EventCard, %{label: card_label})
          ])
        )
      )
    end
  end

  # ── each-in-branch (gate 8a) ────────────────────────────────────────────────
  # Dynamics: 0 = branch. True arm dynamics: 0 = keyed. False arm: none.

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
      attribute(:show_list, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :set_show_list do
        require_atomic?(false)
        argument(:show_list, :boolean, allow_nil?: false)
        change(set_attribute(:show_list, arg(:show_list)))
      end

      update :put_rows do
        require_atomic?(false)
        argument(:rows, {:array, Row}, allow_nil?: false)
        change(set_attribute(:rows, arg(:rows)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box([], [
            if show_list do
              list([], [each(rows, :row, [], [item([], [text(row.label)])])])
            else
              paragraph([], [text("no rows")])
            end
          ])
        )
      )
    end
  end

  # ── branch-in-each (gate 8b) ────────────────────────────────────────────────
  # Dynamics: 0 = keyed. Item dynamics: 0 = branch on row.flag?.
  # On arm (strong) has one dynamic (label); off arm (em) has none.

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
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :put_rows do
        require_atomic?(false)
        argument(:rows, {:array, Row}, allow_nil?: false)
        change(set_attribute(:rows, arg(:rows)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          list([], [
            each(rows, :row, [], [
              item([], [
                if row.flag? do
                  strong([], [text("on:"), text(row.label)])
                else
                  em([], [text("off")])
                end
              ])
            ])
          ])
        )
      )
    end
  end

  # ── each-in-each (gate 8c) ──────────────────────────────────────────────────
  # Dynamics: 0 = outer keyed. Outer item: 0 = text(group.name), 1 = inner keyed.
  # Inner item: 0 = text(it.label).

  defmodule Group do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:group_id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:name, :string, allow_nil?: false, default: "", public?: true)
      attribute(:revision, :integer, allow_nil?: false, default: 0, public?: true)

      attribute(:items, {:array, AshUi.Phoenix.LvWireMatrixTest.Row},
        allow_nil?: false,
        default: [],
        public?: true
      )
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
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
      attribute(:groups, {:array, Group}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :put_groups do
        require_atomic?(false)
        argument(:groups, {:array, Group}, allow_nil?: false)
        change(set_attribute(:groups, arg(:groups)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box([], [
            each(groups, :group, [], [
              box([], [
                strong([], [text(group.name)]),
                list([], [
                  each(group.items, :it, [], [item([], [text(it.label)])])
                ])
              ])
            ])
          ])
        )
      )
    end
  end

  # ── plumbing (same engine path as live_render_test.exs) ─────────────────────

  defp seed(resource, attrs) do
    Ash.Seed.seed!(resource, Map.put(attrs, :session_id, Ash.UUID.generate()))
  end

  defp rows(specs), do: Enum.map(specs, &struct(Row, &1))

  defp run!(page, action, args) do
    page
    |> Ash.Changeset.for_update(action, args,
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)
  end

  defp lv_render(rendered, prints) do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {diff, prints, _components} =
      Diff.render(socket, rendered, prints || Diff.new_fingerprints(), Diff.new_components())

    {diff, prints}
  end

  defp paint(client_state) do
    client_state
    |> Map.delete(:streams)
    |> Diff.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp legacy_paint(%resource{} = record) do
    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(resource),
        record,
        %{},
        target: AshUi.Phoenix.RenderTarget
      )

    {:safe, iodata} =
      AshUi.RenderTarget.Html.render_static(
        tree,
        target: AshUi.Phoenix.RenderTarget
      )

    IO.iodata_to_binary(iodata)
  end

  # mount: full payload, byte-identical to the legacy full renderer
  defp mount(record) do
    {full, prints} = lv_render(LiveRender.build(record, :all), nil)
    client = Client.merge_diff(%{}, full)
    assert paint(client) == legacy_paint(record), "mount drift: #{inspect(full)}"
    {prints, client}
  end

  # apply an action, derive the changed set, LV-render, merge; then assert
  # byte-equality to a fresh full render AND (gate 9) that an immediate no-op
  # render ships an empty diff.
  defp step(%resource{} = page, action, args, prints, client) do
    updated = run!(page, action, args)
    changed = PatchRuntime.changed_addresses(resource, page, updated)

    {diff, prints} = lv_render(LiveRender.build(updated, changed), prints)
    client = Client.merge_diff(client, diff)

    assert paint(client) == legacy_paint(updated),
           "client drift after #{action}: #{inspect(diff)}"

    {noop, _prints} = lv_render(LiveRender.build(updated, MapSet.new()), prints)
    assert noop == %{}, "no-op after #{action} shipped: #{inspect(noop)}"

    {updated, prints, client, diff}
  end

  # integer dynamic positions of a wire diff (drops :s/:p/:r/:k bookkeeping)
  defp dynamic_keys(diff), do: diff |> Map.keys() |> Enum.filter(&is_integer/1) |> Enum.sort()

  defp root_flag_count(value) when is_map(value) do
    own = if Map.get(value, :r) == 1, do: 1, else: 0
    own + Enum.sum(Enum.map(Map.values(value), &root_flag_count/1))
  end

  defp root_flag_count(value) when is_list(value),
    do: Enum.sum(Enum.map(value, &root_flag_count/1))

  defp root_flag_count(_value), do: 0

  # ── gate 1 + 2: scalar text and attr chunk ──────────────────────────────────

  test "gate 1: a scalar text change ships exactly one text dynamic" do
    page = seed(MatrixPage, %{rows: rows([%{message_id: "m1", label: "one"}])})
    {prints, client} = mount(page)
    assert paint(client) =~ "Inbox"

    {_page, _prints, client, diff} = step(page, :retitle, %{title: "Archive"}, prints, client)

    assert diff == %{0 => "Archive"},
           "expected exactly the title text dynamic, got: #{inspect(diff)}"

    assert paint(client) =~ "Archive"
    refute paint(client) =~ "Inbox"
  end

  test "gate 2: an attr-chunk change ships only the changed attribute pair" do
    page = seed(MatrixPage, %{rows: rows([%{message_id: "m1", label: "one"}])})
    {prints, client} = mount(page)
    assert paint(client) =~ ~s(data-status="idle")

    {_page, _prints, client, diff} = step(page, :set_status, %{status: "busy"}, prints, client)

    assert [1] = Map.keys(diff), "expected only the status attr chunk, got: #{inspect(diff)}"

    # The attrs chunk is a nested region: only the changed attribute PAIR
    # ships inside it (fingerprint unchanged, statics/parts stay client-side).
    inner = diff[1] |> Map.filter(fn {key, _v} -> is_integer(key) end) |> Map.values()
    assert [pair] = inner
    assert pair == ~s( data-status="busy")

    assert paint(client) =~ ~s(data-status="busy")
    refute paint(client) =~ ~s(data-status="idle")
  end

  # ── gate 3: branches ────────────────────────────────────────────────────────

  test "gate 3: branch flips ship arm statics; arm-dep changes re-render the arm" do
    page = seed(MatrixPage, %{rows: []})
    {prints, client} = mount(page)
    assert paint(client) =~ "on: alpha"

    # flip true -> false: the new arm subtree ships, statics change via
    # fingerprint (the arm statics ride LiveView's shared-template key :p,
    # with :s as a template index)
    {page, prints, client, diff} = step(page, :set_flag, %{flag: false}, prints, client)
    assert [2] = dynamic_keys(diff)
    assert %{:s => _, 0 => "beta"} = diff[2]
    assert paint(client) =~ "off: beta"
    refute paint(client) =~ "on: alpha"

    # flip false -> true: statics swap back
    {page, prints, client, diff} = step(page, :set_flag, %{flag: true}, prints, client)
    assert [2] = dynamic_keys(diff)
    assert %{:s => _, 0 => "alpha"} = diff[2]
    assert paint(client) =~ "on: alpha"

    # a change to a field read INSIDE the active arm re-renders the arm,
    # dynamics only (fingerprint unchanged -> no :s)
    {page, prints, client, diff} =
      step(page, :set_active_note, %{note: "gamma"}, prints, client)

    assert diff == %{2 => %{0 => "gamma"}}
    assert paint(client) =~ "on: gamma"

    # A change to a field read ONLY in the INACTIVE arm ships NOTHING: arm
    # slots are first-class, so the inactive arm's dep names an `addr/f/...`
    # address, the branch skip gate descends, and the active arm's skeleton
    # gates every dynamic by the changed set — none match. (Formerly this
    # shipped one redundant byte-identical dynamic because branch slot deps
    # subsumed BOTH arms' subtree deps.)
    {page, prints, client, diff} =
      step(page, :set_fallback_note, %{note: "delta"}, prints, client)

    assert diff == %{},
           "inactive-arm change must ship nothing, got: #{inspect(diff)}"

    assert paint(client) =~ "on: gamma"
    refute paint(client) =~ "delta"

    # ...and the queued inactive-arm value appears on the next flip
    {_page, _prints, client, diff} = step(page, :set_flag, %{flag: false}, prints, client)
    assert %{2 => %{:s => _, 0 => "delta"}} = diff
    assert paint(client) =~ "off: delta"

    # Opening a control inside an unchanged outer arm ships both sibling
    # attribute dynamics: the visibility toggle and the populated value.
    control_page = seed(ConditionalControlPage, %{})
    {control_prints, control_client} = mount(control_page)
    assert paint(control_client) =~ "stable sibling"
    refute paint(control_client) =~ "<dialog open"

    value = "prefill — αβ\nsecond line"

    {_control_page, _control_prints, control_client, control_diff} =
      step(
        control_page,
        :open_editor,
        %{editor_text: value},
        control_prints,
        control_client
      )

    assert paint(control_client) =~ "<dialog open"
    assert paint(control_client) =~ ~s(value="prefill — αβ\nsecond line")
    assert inspect(control_diff) =~ "prefill — αβ"
  end

  # ── gate 4: keyed row operations ────────────────────────────────────────────

  test "single-root rendered boundaries emit root tracking; multi-root keyed items do not" do
    page =
      seed(MatrixPage, %{
        rows: rows([%{message_id: "m1", label: "one"}])
      })

    {full, _prints} = lv_render(LiveRender.build(page, :all), nil)

    assert full[:r] == 1
    assert get_in(full, [2, :r]) == 1
    assert get_in(full, [3, :k, 0, 0, :r]) == 1

    child_page = seed(RootTrackedChildHost, %{})
    {child_full, _prints} = lv_render(LiveRender.build(child_page, :all), nil)
    assert root_flag_count(child_full) == 2

    multi_page =
      seed(MultiRootKeyedPage, %{
        rows: rows([%{message_id: "m1", label: "one"}])
      })

    {multi_full, _prints} = lv_render(LiveRender.build(multi_page, :all), nil)
    assert %{0 => keyed} = multi_full
    assert root_flag_count(get_in(keyed, [:k, 0])) == 0

    conditional_page =
      seed(ConditionalSiblingKeyedPage, %{
        rows: rows([%{message_id: "m1", label: "one", flag?: true}])
      })

    {conditional_full, _prints} =
      lv_render(LiveRender.build(conditional_page, :all), nil)

    assert %{0 => conditional_keyed} = conditional_full
    conditional_entry = get_in(conditional_keyed, [:k, 0])
    refute Map.has_key?(conditional_entry, :r)
    assert root_flag_count(conditional_entry) == 1
  end

  test "gate 4: keyed content change / remove / insert / reorder / clear wire shapes" do
    page =
      seed(MatrixPage, %{
        rows:
          rows([
            %{message_id: "m1", label: "one"},
            %{message_id: "m2", label: "two"},
            %{message_id: "m3", label: "three"}
          ])
      })

    {prints, client} = mount(page)

    # A single row content change ships only that entry index and the nested
    # text slot that reads the changed label; unchanged row attrs are omitted.
    changed = [
      %{message_id: "m1", label: "one"},
      %{message_id: "m2", label: "TWO"},
      %{message_id: "m3", label: "three"}
    ]

    {page, prints, client, diff} = step(page, :put_rows, %{rows: changed}, prints, client)

    assert [3] = Map.keys(diff)
    assert %{k: keyed} = diff[3]
    refute Map.has_key?(diff[3], :s)
    assert keyed[:kc] == 3
    assert map_size(keyed) == 2, "expected exactly one entry + kc, got: #{inspect(keyed)}"
    assert keyed[1] == %{0 => %{1 => "TWO"}}
    assert paint(client) =~ "TWO"

    # remove ships integer moves + kc only
    {page, prints, client, diff} =
      step(
        page,
        :put_rows,
        %{rows: [%{message_id: "m1", label: "one"}, %{message_id: "m3", label: "three"}]},
        prints,
        client
      )

    assert %{3 => %{k: keyed}} = diff
    assert keyed == %{1 => 2, :kc => 2}, "remove should be moves+kc: #{inspect(keyed)}"
    refute paint(client) =~ "TWO"

    # insert ships only the new entry dynamics + integer moves
    {page, prints, client, diff} =
      step(
        page,
        :put_rows,
        %{
          rows: [
            %{message_id: "m0", label: "zero"},
            %{message_id: "m1", label: "one"},
            %{message_id: "m3", label: "three"}
          ]
        },
        prints,
        client
      )

    assert %{3 => %{k: keyed}} = diff
    assert keyed[:kc] == 3
    assert %{0 => %{0 => _attrs, 1 => "zero", :r => 1}} = keyed[0]
    assert keyed[1] == 0
    assert keyed[2] == 1
    assert map_size(keyed) == 4
    assert paint(client) =~ "zero"

    # pure reorder ships integer moves only (no declared index, no parent change)
    {page, prints, client, diff} =
      step(
        page,
        :put_rows,
        %{
          rows: [
            %{message_id: "m3", label: "three"},
            %{message_id: "m0", label: "zero"},
            %{message_id: "m1", label: "one"}
          ]
        },
        prints,
        client
      )

    assert %{3 => %{k: keyed}} = diff

    assert keyed == %{0 => 2, 1 => 0, 2 => 1, :kc => 3},
           "pure reorder should be integer moves only: #{inspect(keyed)}"

    # clearing to empty ships kc 0 only
    {_page, _prints, client, diff} = step(page, :put_rows, %{rows: []}, prints, client)

    assert %{3 => %{k: keyed}} = diff
    assert keyed == %{kc: 0}
    refute paint(client) =~ "zero"
  end

  # ── gate 5: declared index ──────────────────────────────────────────────────

  test "gate 5: pure reorder with a declared index re-renders moved rows with new ordinals" do
    page =
      seed(OrdinalPage, %{
        rows:
          rows([
            %{message_id: "a", label: "ant"},
            %{message_id: "b", label: "bee"},
            %{message_id: "c", label: "cow"}
          ])
      })

    {prints, client} = mount(page)
    assert paint(client) =~ "0: ant"
    assert paint(client) =~ "1: bee"
    assert paint(client) =~ "2: cow"

    {_page, _prints, client, diff} =
      step(
        page,
        :put_rows,
        %{
          rows: [
            %{message_id: "c", label: "cow"},
            %{message_id: "a", label: "ant"},
            %{message_id: "b", label: "bee"}
          ]
        },
        prints,
        client
      )

    assert %{0 => %{k: keyed}} = diff
    assert keyed[:kc] == 3

    # every moved row re-renders whole: [previous_index, child_diff] with the
    # NEW ordinal as its first dynamic
    assert [2, %{0 => %{0 => "0", 1 => "cow"}}] = keyed[0]
    assert [0, %{0 => %{0 => "1", 1 => "ant"}}] = keyed[1]
    assert [1, %{0 => %{0 => "2", 1 => "bee"}}] = keyed[2]

    assert paint(client) =~ "0: cow"
    assert paint(client) =~ "1: ant"
    assert paint(client) =~ "2: bee"
  end

  # ── gate 6: parent dep in rows ──────────────────────────────────────────────

  test "gate 6: a parent-scalar change re-renders rows per entry, never the container" do
    page =
      seed(MatrixPage, %{
        rows:
          rows([
            %{message_id: "m1", label: "one"},
            %{message_id: "m2", label: "two"},
            %{message_id: "m3", label: "three"}
          ])
      })

    {prints, client} = mount(page)
    refute paint(client) =~ "data-sel"

    {_page, _prints, client, diff} =
      step(page, :select, %{selected_id: "m2"}, prints, client)

    # ONLY the keyed slot ships (selected_id is read only inside the row template)
    assert [3] = Map.keys(diff)
    assert %{k: keyed} = diff[3]
    refute Map.has_key?(diff[3], :s), "container statics must not re-ship: #{inspect(diff)}"
    assert keyed[:kc] == 3

    # per-entry updates: every row reads __parent__.selected_id, so every entry
    # re-renders as a map (row granularity), no integer moves, no replacement.
    # Diff scoping narrows WITHIN each entry: only the attrs slot (position 0)
    # reads selected_id, and inside its nested attr region only the data-sel
    # PAIR re-ships — the row.label slot (position 1) does not depend on the
    # changed parent field and stays unchanged (nil), never re-shipping.
    for index <- 0..2 do
      assert %{0 => %{0 => attrs} = row} = keyed[index]

      inner = attrs |> Map.filter(fn {key, _v} -> is_integer(key) end) |> Map.values()
      assert [pair] = inner
      assert pair in ["", " data-sel"]

      refute Map.has_key?(row, 1),
             "the row.label slot does not read selected_id and must not re-ship: #{inspect(row)}"
    end

    assert paint(client) =~ "data-sel"
  end

  # ── gate 7: child render ────────────────────────────────────────────────────

  test "gate 7: child render re-renders on its input change; unrelated changes ship nothing for it" do
    page = seed(ChildHostPage, %{})
    {prints, client} = mount(page)
    assert paint(client) =~ "card: c1"

    # unrelated field: only the sibling text dynamic ships, nothing for the child
    {page, prints, client, diff} = step(page, :set_other, %{other: "o2"}, prints, client)
    assert diff == %{0 => "o2"}, "child must not ship on unrelated change: #{inspect(diff)}"

    # Child input field: ChildCard is embedded and event-free, so it INLINES
    # at compile time — no child Rendered boundary exists on the wire; the
    # substituted leaf is a direct dynamic of the parent and ships alone.
    {_page, _prints, client, diff} =
      step(page, :set_card_label, %{card_label: "c2"}, prints, client)

    assert diff == %{1 => "c2"}, "expected only the inlined child leaf: #{inspect(diff)}"
    assert paint(client) =~ "card: c2"
    refute paint(client) =~ "card: c1"
  end

  test "gate 7b: an event-bearing embedded child keeps its runtime boundary on the wire" do
    page = seed(EventChildHostPage, %{})
    {prints, client} = mount(page)
    assert paint(client) =~ "ecard: e1"

    # unrelated field: only the sibling text dynamic ships, nothing for the child
    {page, prints, client, diff} = step(page, :set_other, %{other: "o2"}, prints, client)
    assert diff == %{0 => "o2"}, "child must not ship on unrelated change: #{inspect(diff)}"

    # input change: the child cannot inline (its element carries an event
    # binding — the key crosses its boundary), so the child Rendered
    # boundary stays visible and only its changed dynamics ship inside it.
    {_page, _prints, client, diff} =
      step(page, :set_card_label, %{card_label: "e2"}, prints, client)

    assert map_size(diff) == 1 and is_map(diff[1]),
           "expected only the child boundary re-render: #{inspect(diff)}"

    assert paint(client) =~ "ecard: e2"
    refute paint(client) =~ "ecard: e1"
  end

  test "fragment-only dependency changes ship only the child boundary and repaint byte-identically" do
    page = seed(FragmentHostPage, %{})
    {prints, client} = mount(page)
    assert paint(client) =~ ">f1</strong>"

    {_page, _prints, client, diff} =
      step(
        page,
        :set_fragment_label,
        %{fragment_label: "f2"},
        prints,
        client
      )

    assert map_size(diff) == 1
    assert Enum.all?(Map.values(diff), &is_map/1)
    assert paint(client) =~ ">f2</strong>"
    refute paint(client) =~ ">f1</strong>"
  end

  # ── gate 8: nested combinations ─────────────────────────────────────────────

  test "gate 8a: each-in-branch — row updates stay keyed-minimal inside the arm; flips swap whole arms" do
    page =
      seed(EachInBranchPage, %{
        rows: rows([%{message_id: "r1", label: "red"}, %{message_id: "r2", label: "blue"}])
      })

    {prints, client} = mount(page)
    assert paint(client) =~ "red"
    assert paint(client) =~ "blue"

    # a row change while the branch is ON: the branch re-ships its arm, but the
    # comprehension prints survive -> keyed diff stays entry-minimal
    {page, prints, client, diff} =
      step(
        page,
        :put_rows,
        %{rows: [%{message_id: "r1", label: "crimson"}, %{message_id: "r2", label: "blue"}]},
        prints,
        client
      )

    assert %{0 => arm} = diff
    refute Map.has_key?(arm, :s)
    assert %{0 => %{k: keyed}} = arm
    assert keyed == %{0 => %{0 => %{0 => "crimson"}}, :kc => 2}
    assert paint(client) =~ "crimson"

    # flip OFF with items present: the false arm ships (statics only — no dynamics)
    {page, prints, client, diff} = step(page, :set_show_list, %{show_list: false}, prints, client)
    assert %{0 => arm} = diff
    assert Map.has_key?(arm, :s)

    assert Map.drop(arm, [:r]) |> map_size() == 1,
           "false arm has no dynamics: #{inspect(arm)}"

    assert arm[:r] == 1
    assert paint(client) =~ "no rows"
    refute paint(client) =~ "crimson"

    # flip back ON: arm statics + a fresh full comprehension (its prints were dropped)
    {_page, _prints, client, diff} =
      step(page, :set_show_list, %{show_list: true}, prints, client)

    assert %{0 => arm} = diff
    assert Map.has_key?(arm, :s)
    assert arm[:r] == 1
    assert %{0 => %{:s => _, :k => keyed}} = arm
    assert keyed[:kc] == 2
    assert %{0 => %{0 => "crimson", :r => 1}} = keyed[0]
    assert %{0 => %{0 => "blue", :r => 1}} = keyed[1]
    assert paint(client) =~ "crimson"
    refute paint(client) =~ "no rows"
  end

  test "gate 8b: branch-in-each — toggling one item's condition ships only that entry" do
    page =
      seed(BranchInEachPage, %{
        rows:
          rows([
            %{message_id: "x", label: "xen", flag?: false},
            %{message_id: "y", label: "yak", flag?: false}
          ])
      })

    {prints, client} = mount(page)
    refute paint(client) =~ "yak"

    # toggle y ON: only entry 1 ships; its branch swaps arms (statics inside the entry)
    {page, prints, client, diff} =
      step(
        page,
        :put_rows,
        %{
          rows: [
            %{message_id: "x", label: "xen", flag?: false},
            %{message_id: "y", label: "yak", flag?: true}
          ]
        },
        prints,
        client
      )

    assert %{0 => %{k: keyed}} = diff
    assert keyed[:kc] == 2
    assert map_size(keyed) == 2, "only the toggled entry ships: #{inspect(keyed)}"
    assert %{0 => %{0 => arm}} = keyed[1]
    assert %{:s => _, :r => 1, 0 => "yak"} = arm
    assert paint(client) =~ "on:yak"

    # toggle y back OFF: arm swaps to the static em arm
    {_page, _prints, client, diff} =
      step(
        page,
        :put_rows,
        %{
          rows: [
            %{message_id: "x", label: "xen", flag?: false},
            %{message_id: "y", label: "yak", flag?: false}
          ]
        },
        prints,
        client
      )

    assert %{0 => %{k: keyed}} = diff
    assert map_size(keyed) == 2
    assert %{0 => %{0 => arm}} = keyed[1]
    assert Map.has_key?(arm, :s)
    assert arm[:r] == 1
    refute paint(client) =~ "yak"
  end

  test "gate 8c: each-in-each — an inner item change ships one outer entry with an inner keyed diff" do
    page =
      seed(NestedEachPage, %{
        groups: [
          struct(Group, %{
            group_id: "g1",
            name: "First",
            items: rows([%{message_id: "i1", label: "one"}, %{message_id: "i2", label: "two"}])
          }),
          struct(Group, %{
            group_id: "g2",
            name: "Second",
            revision: 0,
            items: rows([%{message_id: "i3", label: "three"}, %{message_id: "i4", label: "four"}])
          })
        ]
      })

    {prints, client} = mount(page)
    assert paint(client) =~ "four"

    {_page, _prints, client, diff} =
      step(
        page,
        :put_groups,
        %{
          groups: [
            %{
              group_id: "g1",
              name: "First",
              items: [%{message_id: "i1", label: "one"}, %{message_id: "i2", label: "two"}]
            },
            %{
              group_id: "g2",
              name: "Second",
              revision: 1,
              items: [%{message_id: "i3", label: "three"}, %{message_id: "i4", label: "quattro"}]
            }
          ]
        },
        prints,
        client
      )

    assert %{0 => %{k: outer}} = diff
    assert outer[:kc] == 2
    assert map_size(outer) == 2, "only the touched outer entry ships: #{inspect(outer)}"

    # The compiled item-field index targets the nested `items` dynamic. The
    # unchanged outer name is omitted, while the unreferenced `revision`
    # metadata change is ignored and the inner comprehension remains
    # keyed-minimal down to the changed label slot.
    assert %{0 => %{1 => %{k: inner}}} = outer[1]

    assert inner == %{1 => %{0 => %{0 => "quattro"}}, :kc => 2},
           "inner keyed diff must be entry-minimal: #{inspect(inner)}"

    assert paint(client) =~ "quattro"
    refute paint(client) =~ "four"
  end

  # ── gate 10: randomized property ────────────────────────────────────────────

  test "gate 10: 50 random action steps stay byte-identical to fresh full renders (fixed seed)" do
    :rand.seed(:exsss, {2026, 7, 10})

    page =
      seed(MatrixPage, %{
        rows:
          rows([
            %{message_id: "m1", label: "label-1", flag?: false},
            %{message_id: "m2", label: "label-2", flag?: true},
            %{message_id: "m3", label: "label-3", flag?: false},
            %{message_id: "m4", label: "label-4", flag?: true}
          ])
      })

    {prints, client} = mount(page)

    Enum.reduce(1..50, {page, prints, client}, fn step_no, {page, prints, client} ->
      {action, args} = random_matrix_action(page, step_no)
      {page, prints, client, _diff} = step(page, action, args, prints, client)
      {page, prints, client}
    end)
  end

  defp random_matrix_action(page, step_no) do
    current = Enum.map(page.rows, &%{message_id: &1.message_id, label: &1.label, flag?: &1.flag?})

    op =
      Enum.random([
        :retitle,
        :set_status,
        :toggle_flag,
        :set_active_note,
        :set_fallback_note,
        :select,
        :relabel,
        :relabel,
        :toggle_row_flag,
        :insert,
        :insert,
        :remove,
        :reorder,
        :reorder,
        :clear
      ])

    op =
      if current == [] and op in [:relabel, :toggle_row_flag, :remove, :reorder, :clear],
        do: :insert,
        else: op

    case op do
      :retitle ->
        {:retitle, %{title: "title-#{:rand.uniform(4)}"}}

      :set_status ->
        {:set_status, %{status: "status-#{:rand.uniform(4)}"}}

      :toggle_flag ->
        {:set_flag, %{flag: not page.flag}}

      :set_active_note ->
        {:set_active_note, %{note: "active-#{:rand.uniform(4)}"}}

      :set_fallback_note ->
        {:set_fallback_note, %{note: "fallback-#{:rand.uniform(4)}"}}

      :select ->
        {:select, %{selected_id: Enum.random([nil | Enum.map(current, & &1.message_id)])}}

      :relabel ->
        index = :rand.uniform(length(current)) - 1
        {:put_rows, %{rows: List.update_at(current, index, &%{&1 | label: "relabel-#{step_no}"})}}

      :toggle_row_flag ->
        index = :rand.uniform(length(current)) - 1
        {:put_rows, %{rows: List.update_at(current, index, &%{&1 | flag?: not &1.flag?})}}

      :insert ->
        index = :rand.uniform(length(current) + 1) - 1

        row = %{message_id: "m-#{step_no}", label: "fresh-#{step_no}", flag?: false}
        {:put_rows, %{rows: List.insert_at(current, index, row)}}

      :remove ->
        {:put_rows, %{rows: List.delete_at(current, :rand.uniform(length(current)) - 1)}}

      :reorder ->
        {:put_rows, %{rows: Enum.shuffle(current)}}

      :clear ->
        {:put_rows, %{rows: []}}
    end
  end
end
