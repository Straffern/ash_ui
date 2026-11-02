defmodule AshUi.Phoenix.LiveRenderTest do
  @moduledoc """
  The patch engine drives LiveView's OWN diff engine end to end:

    server: AshUi.Phoenix.LiveRender.build + Phoenix.LiveView.Diff.render
    change source: AshUi.Patch.Runtime.changed_addresses (NO tree diffing)
    client: Phoenix.LiveViewTest.Diff.merge_diff (LiveView's client simulation)

  Gates:
  1. mount payload paints byte-identical to the legacy full renderer
  2. a scalar action ships ONLY the reached dynamics; client merge stays
     byte-identical to a fresh full render
  3. keyed toggle/remove/insert ship LiveView keyed diffs (entry-minimal)
  4. a no-op render ships an empty diff
  """
  use ExUnit.Case, async: false

  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Runtime, as: PatchRuntime
  alias AshUi.Phoenix.LiveRender
  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveViewTest.Diff, as: Client

  defmodule Fold do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:message_id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:expanded?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule Page do
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
      attribute(:folds, {:array, Fold}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
        argument(:folds, {:array, Fold}, allow_nil?: true)
        change(set_attribute(:folds, arg(:folds), set_when_nil?: false))
      end

      update :retitle do
        require_atomic?(false)
        argument(:title, :string, allow_nil?: false)
        change(set_attribute(:title, arg(:title)))
      end

      update :put_folds do
        require_atomic?(false)
        argument(:folds, {:array, Fold}, allow_nil?: false)
        change(set_attribute(:folds, arg(:folds)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [part: :lvr_root], [
            heading(:title, [], [text(title)]),
            list(:folds, [part: :lvr_folds], [
              each(folds, :fold, [], [
                item(:row, [part: :lvr_row], [text(fold.message_id)])
              ])
            ])
          ])
        )
      )
    end
  end

  defmodule FailingMountPage do
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
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
        change(fn changeset, _context ->
          Ash.Changeset.add_error(
            changeset,
            "internal actor id=private-user csrf-secret=private-value stack frame=private-call"
          )
        end)
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(box(:root, [], [text("unused")])))
    end
  end

  defmodule HookPage do
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
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(
            :hook,
            [client_driver: :agent, data: [title: title]],
            [text(title)]
          )
        )
      )
    end
  end

  defmodule FragmentShell do
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
        expr(section(:fragment_shell, [], [content]))
      )
    end
  end

  defmodule FragmentHookPage do
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
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          render(FragmentShell, %{
            content:
              box(
                :fragment_hook,
                [client_driver: :agent, data: [title: title]],
                [text(title)]
              )
          })
        )
      )
    end
  end

  defmodule FragmentErrorPage do
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
      attribute(:name, :string, allow_nil?: false, default: "", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      update :save do
        require_atomic?(false)
        accept([:name])
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          render(FragmentShell, %{
            content:
              section(:form, [], [
                input(:name_input, [name: "name", value: name, on_input: :save], []),
                text(field_errors(:name))
              ])
          })
        )
      )
    end
  end

  defmodule StrictChild do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      authorizers: [Ash.Policy.Authorizer],
      validate_domain_inclusion?: false

    policies do
      policy action_type(:create) do
        authorize_if(always())
      end
    end

    attributes do
      attribute(:count, :integer, allow_nil?: false, public?: true)
    end

    actions do
      defaults(create: [:count])
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text(count)))
    end
  end

  defmodule InvalidChildPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      authorizers: [Ash.Policy.Authorizer],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:count, :string, allow_nil?: false, default: "not-an-integer", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(render(StrictChild, %{count: count}))
      )
    end
  end

  defmodule ErrorChild do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults(create: [:label])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:child_error, [], [
            text(path(find_by(errors(), [:field], nil), [:message]))
          ])
        )
      )
    end
  end

  defmodule ErrorChildPage do
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
      attribute(:label, :string, allow_nil?: false, default: "error", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(render(ErrorChild, %{label: label}))
      )
    end
  end

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp seed(folds) do
    Ash.Seed.seed!(Page, %{
      session_id: Ash.UUID.generate(),
      folds: Enum.map(folds, &struct(Fold, &1))
    })
  end

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

  defp legacy_paint(record) do
    static_paint(Page, record)
  end

  defp static_paint(resource, record) do
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

  # apply an action, derive the changed set, LV-render, merge
  defp step(page, action, args, prints, client) do
    updated = run!(page, action, args)
    changed = PatchRuntime.changed_addresses(Page, page, updated)

    {diff, prints} = lv_render(LiveRender.build(updated, changed), prints)
    client = Client.merge_diff(client, diff)

    assert paint(client) == legacy_paint(updated),
           "client drift after #{action}: #{inspect(diff)}"

    {updated, prints, client, diff}
  end

  # ── gates ──────────────────────────────────────────────────────────────────

  test "LiveRender hook ids match the static renderer for dynamic attribute chunks" do
    page = %HookPage{session_id: Ash.UUID.generate(), title: "Archive"}

    {full, _prints} = lv_render(LiveRender.build(page, :all), nil)
    live_html = paint(Client.merge_diff(%{}, full))
    static_html = static_paint(HookPage, page)

    assert live_html == static_html
    assert live_html =~ ~s(phx-hook="AshUiClient")
    assert [_, id] = Regex.run(~r/id="([^"]+)"/, live_html)
    assert id =~ ~r/^bp-[0-9a-f]{12}$/
  end

  test "RenderTree-valued child inputs retain Phoenix hook ids in LiveView materialization" do
    page = %FragmentHookPage{session_id: Ash.UUID.generate(), title: "Archive"}

    {full, _prints} = lv_render(LiveRender.build(page, :all), nil)
    live_html = paint(Client.merge_diff(%{}, full))
    static_html = static_paint(FragmentHookPage, page)

    assert live_html == static_html
    assert live_html =~ ~s(phx-hook="AshUiClient")
    assert [_, id] = Regex.run(~r/id="([^"]+)"/, live_html)
    assert id =~ ~r/^bp-[0-9a-f]{12}$/
  end

  test "dispatch errors patch controls authored inside nested RenderTree-valued child inputs" do
    page = %FragmentErrorPage{session_id: Ash.UUID.generate(), name: ""}
    table = Compiler.table(FragmentErrorPage, :view, target: AshUi.Phoenix.RenderTarget)

    {full, prints} = lv_render(LiveRender.build(page, :all, table: table), nil)
    client = Client.merge_diff(%{}, full)

    error =
      Ash.Error.Changes.Required.exception(
        field: :name,
        type: :attribute,
        resource: FragmentErrorPage
      )

    {diff, _prints} =
      lv_render(
        LiveRender.build(page, MapSet.new(table.error_slots), table: table, errors: [error]),
        prints
      )

    html = client |> Client.merge_diff(diff) |> paint()
    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(data-ash-ui-error="is required")
    assert html =~ "is required"
  end

  test "invalid dynamic child input renders page error state instead of crashing LiveView diff" do
    page = %InvalidChildPage{session_id: Ash.UUID.generate()}

    {diff, _prints} = lv_render(LiveRender.build(page, :all), nil)
    html = paint(Client.merge_diff(%{}, diff))

    assert html =~ ~s(role="alert")
    assert html =~ ~s(data-ash-ui-error="invalid-child-input")
    # the ORIGINAL Ash error projects through the standard surface —
    # no invented message, no second vocabulary
    assert html =~ "count: is invalid"
    refute html =~ "Invalid input for"
  end

  test "fieldless Ash errors remain visible through a rendered child boundary" do
    page = %ErrorChildPage{session_id: Ash.UUID.generate()}
    error = %Ash.Error.Changes.InvalidChanges{message: "couldn't save album"}

    {diff, _prints} = lv_render(LiveRender.build(page, :all, errors: [error]), nil)
    html = paint(Client.merge_diff(%{}, diff))

    assert html =~ "couldn't save album"
  end

  test "mount + scalar + keyed changes ride LiveView's diff engine minimally and stay byte-exact" do
    page = seed([%{message_id: "m1"}, %{message_id: "m2", expanded?: true}, %{message_id: "m3"}])

    # mount: full payload, byte-identical to the legacy renderer
    {full, prints} = lv_render(LiveRender.build(page, :all), nil)
    client = Client.merge_diff(%{}, full)
    assert paint(client) == legacy_paint(page)
    assert paint(client) =~ "m2"

    # scalar: only the title text dynamic ships
    {page, prints, client, diff} = step(page, :retitle, %{title: "Archive"}, prints, client)

    flat = flatten_diff(diff)
    assert Enum.count(flat, &is_binary/1) == 1, "expected one text dynamic, got: #{inspect(diff)}"
    assert paint(client) =~ "Archive"

    # keyed content change: LiveView keyed diff, single entry
    folds = [
      %{message_id: "m1"},
      %{message_id: "m2", expanded?: false},
      %{message_id: "m3"}
    ]

    {page, prints, client, diff} = step(page, :put_folds, %{folds: folds}, prints, client)

    # the changed field is not rendered by the row template: entry change
    # tracking follows RENDERED deps, so nothing ships at all
    assert collect_keyed(diff) == []

    # keyed remove + insert + reorder in one action
    folds = [%{message_id: "m9"}, %{message_id: "m3"}, %{message_id: "m1"}]

    {_page, prints, client, diff} = step(page, :put_folds, %{folds: folds}, prints, client)

    assert [keyed] = collect_keyed(diff)
    assert keyed[:kc] == 3
    assert paint(client) =~ "m9"
    refute paint(client) =~ "m2"

    # no-op render ships nothing
    {diff, _prints} = lv_render(LiveRender.build(_page = run_noop(), MapSet.new()), prints)
    assert diff == %{}
  end

  defp run_noop do
    # any record works: with an empty changed set every dynamic returns nil
    seed([])
  end

  test "the bridge changed-set path (stateless changed_addresses) is wire-minimal too" do
    page = seed([%{message_id: "m1"}])

    {full, prints} = lv_render(LiveRender.build(page, :all), nil)
    client = Client.merge_diff(%{}, full)

    updated = run!(page, :retitle, %{title: "Bridged"})
    changed = PatchRuntime.changed_addresses(Page, page, updated)

    {diff, _prints} = lv_render(LiveRender.build(updated, changed), prints)
    client = Client.merge_diff(client, diff)

    flat = flatten_diff(diff)
    assert Enum.count(flat, &is_binary/1) == 1, "expected one dynamic, got: #{inspect(diff)}"
    assert paint(client) == legacy_paint(updated)
  end

  test "P1-1: binding keys inside keyed rows round-trip through the REAL render output" do
    defmodule EventRow do
      @moduledoc false
      use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

      attributes do
        attribute(:message_id, :string, primary_key?: true, allow_nil?: false, public?: true)
      end

      actions do
        defaults([:read, :destroy, create: :*, update: :*])
      end
    end

    defmodule EventListPage do
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
        attribute(:rows, {:array, EventRow}, allow_nil?: false, default: [], public?: true)
      end

      identities do
        identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
      end

      actions do
        defaults([:read])

        create(:mount)

        update :pick do
          require_atomic?(false)
          argument(:id, :string, allow_nil?: false)
        end
      end

      calculations do
        calculate(
          :view,
          AshUi.Type.RenderTree,
          expr(
            list(:rows, [part: :ev_rows], [
              each(rows, :row, [], [
                item(
                  :entry,
                  [part: :ev_row, on_click: :pick, action_input: %{id: row.message_id}],
                  [
                    text(row.message_id)
                  ]
                )
              ])
            ])
          )
        )
      end
    end

    page =
      Ash.Seed.seed!(EventListPage, %{
        session_id: Ash.UUID.generate(),
        rows: [struct(EventRow, %{message_id: "m7"})]
      })

    {full, _prints} = lv_render(LiveRender.build(page, :all), nil)
    html = paint(Client.merge_diff(%{}, full))

    # the REAL rendered row must carry the item key in its binding key
    assert [_, emitted_key] =
             Regex.run(~r/phx-[\w-]+="ash_ui:dispatch:([^"]+)"/, html),
           "no native event binding in: #{html}"

    assert emitted_key =~ AshUi.EventBinding.key_component("m7"),
           "row key missing from binding key: #{emitted_key}"

    assert {:ok, binding, {:root}} = AshUi.Patch.Bindings.resolve(page, emitted_key)
    assert inspect(binding.args_exprs) =~ "m7"
  end

  test "render_shell builds the differential Rendered straight from assigns" do
    page = seed([%{message_id: "m1"}])

    rendered =
      AshUi.Phoenix.render_shell(%{
        ash_ui_record: page,
        ash_ui_changed: :all
      })

    assert %Phoenix.LiveView.Rendered{} = rendered

    {full, _prints} = lv_render(rendered, nil)
    assert paint(Client.merge_diff(%{}, full)) == legacy_paint(page)

    # a missing record renders an empty shell, never raises
    assert %Phoenix.LiveView.Rendered{} =
             AshUi.Phoenix.render_shell(%{ash_ui_record: nil})
  end

  test "mount failures render a compact pane error and retain detail in host logs" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}, private: %{}}
    session_id = Ash.UUID.generate()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, mounted} =
                 AshUi.Phoenix.mount(
                   FailingMountPage,
                   %{},
                   %{"ash_ui_session_id" => session_id},
                   socket,
                   otp_app: :ash_ui_phoenix
                 )

        rendered = AshUi.Phoenix.render_shell(mounted.assigns)
        {full, _prints} = lv_render(rendered, nil)
        html = full |> then(&Client.merge_diff(%{}, &1)) |> paint()

        assert html =~ "This view could not be opened."
        refute html =~ "private-user"
        refute html =~ "csrf-secret"
        refute html =~ "stack frame"
      end)

    assert log =~ "AshUi mount failed"
    assert log =~ "private-user"
  end

  defp flatten_diff(%{} = diff) do
    Enum.flat_map(diff, fn
      {k, %{} = nested} when is_integer(k) -> flatten_diff(nested)
      {k, v} when is_integer(k) -> [v]
      _other -> []
    end)
  end

  defp flatten_diff(_other), do: []

  defp collect_keyed(%{} = diff) do
    direct = if Map.has_key?(diff, :k), do: [diff[:k]], else: []

    nested =
      Enum.flat_map(diff, fn
        {k, %{} = value} when is_integer(k) -> collect_keyed(value)
        _other -> []
      end)

    direct ++ nested
  end
end
