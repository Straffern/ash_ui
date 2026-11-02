defmodule AshUi.Phoenix.E2eBridgeTest do
  @moduledoc """
  Production-path end-to-end: the ACTUAL bridge functions drive the full
  loop — record + cached table in socket assigns → render_shell → real
  Phoenix.LiveView.Diff → wire diff → LV client merge → browser-shaped
  dispatch params through runtime_handle_event → the row's own action →
  changed set → minimal diff → byte-identical client. Plus: dispatch
  errors surface as page error state (never a silent no-op), stale keys
  reject, and the reload path re-renders from row truth.
  """
  use ExUnit.Case, async: false

  alias AshUi.Patch.Compiler
  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveViewTest.Diff, as: Client

  defmodule Row do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:row_id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
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
      attribute(:selected_id, :string, allow_nil?: false, default: "none", public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, :destroy])

      create(:mount)

      update :select do
        require_atomic?(false)
        argument(:id, :string, allow_nil?: false)

        validate(fn changeset, _context ->
          case Ash.Changeset.get_argument(changeset, :id) do
            "forbidden" -> {:error, field: :id, message: "forbidden target"}
            _ok -> :ok
          end
        end)

        change(set_attribute(:selected_id, arg(:id)))
      end

      update :maintenance do
        require_atomic?(false)
        change(set_attribute(:selected_id, "maintenance-ran"))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [part: :e2e_root], [
            inline(:sel, [], [text(selected_id)]),
            list(:rows, [part: :e2e_rows], [
              each(rows, :row, [], [
                item(
                  :entry,
                  [part: :e2e_row, on_click: :select, action_input: %{id: row.row_id}],
                  [text(row.label)]
                )
              ])
            ])
          ])
        )
      )
    end
  end

  defmodule EmbeddedToggle do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:name, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:enabled?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    actions do
      create(:create) do
        primary?(true)
        accept([:name, :enabled?])
      end

      update(:toggle) do
        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :enabled?, !changeset.data.enabled?)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(button(:toggle, [type: :button, on_click: :toggle], [text(to_string(enabled?))]))
      )
    end
  end

  defmodule EmbeddedPage do
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
      attribute(:toggle, EmbeddedToggle, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, update: :*])
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(render(EmbeddedToggle, toggle)))
    end
  end

  defmodule StoreToggle do
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
      uuid_primary_key(:id)
      attribute(:session_id, :uuid, allow_nil?: false, public?: false)
      attribute(:row_id, :string, allow_nil?: false, public?: true)
      attribute(:enabled?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id, :row_id],
        pre_check_with: AshUi.AshDomainFallback
      )
    end

    actions do
      defaults([:read])

      create :mount do
        accept([:row_id])
      end

      update :toggle do
        require_atomic?(false)

        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :enabled?, not changeset.data.enabled?)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          button(:store_toggle, [type: :button, on_click: :toggle], [
            text(row_id <> ":" <> to_string(enabled?))
          ])
        )
      )
    end
  end

  defmodule StoreChildPage do
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
      attribute(:session_id, :uuid, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:store_toggles, StoreToggle,
        source_attribute: :session_id,
        destination_attribute: :session_id,
        public?: true
      )
    end

    actions do
      defaults([:read])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          list(:store_rows, [], [
            each(rows, :row, [key: row.row_id], [
              item(:store_row, [data: [row: row.row_id]], [
                render(AshUi.Phoenix.E2eBridgeTest.StoreToggle, %{
                  row_id: row.row_id
                })
              ])
            ])
          ])
        )
      )
    end
  end

  # ── bridge-shaped socket ───────────────────────────────────────────────────

  test "mount inherits the canonical actor tenant when no tenant option is supplied" do
    session_id = Ash.UUID.generate()

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{}
    }

    assert {:ok, mounted} =
             AshUi.Phoenix.mount(
               Page,
               %{},
               %{"ash_ui_session_id" => session_id},
               socket,
               actor: %{id: "tenant-user", tenant: "tenant-a"},
               otp_app: :ash_ui_phoenix
             )

    assert mounted.assigns.ash_ui_tenant == "tenant-a"
  end

  defp mount_socket(rows) do
    record =
      Ash.Seed.seed!(Page, %{
        session_id: Ash.UUID.generate(),
        rows: Enum.map(rows, &struct(Row, &1))
      })

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        ash_ui_resource: Page,
        ash_ui_view: :view,
        ash_ui_tables: %{
          {Page, :view, AshUi.Phoenix.RenderTarget} =>
            Compiler.table(Page, target: AshUi.Phoenix.RenderTarget)
        },
        ash_ui_session_id: record.session_id,
        ash_ui_actor: nil,
        ash_ui_record: record,
        ash_ui_changed: :all,
        ash_ui_params: %{}
      }
    }
  end

  defp render(socket, prints) do
    rendered = AshUi.Phoenix.render_shell(socket.assigns)

    lv_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {diff, prints, _components} =
      Diff.render(lv_socket, rendered, prints || Diff.new_fingerprints(), Diff.new_components())

    {diff, prints}
  end

  defp paint(client) do
    client |> Map.delete(:streams) |> Diff.to_iodata() |> IO.iodata_to_binary()
  end

  defp legacy_paint(record) do
    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(Page),
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

  defp store_child_paint(record) do
    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(StoreChildPage),
        record,
        %{},
        target: AshUi.Phoenix.RenderTarget,
        session_id: record.session_id
      )

    {:safe, iodata} =
      AshUi.RenderTarget.Html.render_static(
        tree,
        target: AshUi.Phoenix.RenderTarget
      )

    IO.iodata_to_binary(iodata)
  end

  defp emitted_row_binding(html, row_id) do
    keys =
      ~r/phx-[\w-]+="ash_ui:dispatch:([^"]+)"/
      |> Regex.scan(html)
      |> Enum.map(fn [_, key] -> key end)

    prefix = AshUi.EventBinding.key_component(row_id) <> "."
    Enum.find(keys, &String.starts_with?(&1, prefix)) || List.first(keys)
  end

  # ── the loop ───────────────────────────────────────────────────────────────

  test "browser dispatch on a keyed row rides the whole bridge loop wire-minimally" do
    socket = mount_socket([%{row_id: "m1", label: "one"}, %{row_id: "m2", label: "two"}])

    {full, prints} = render(socket, nil)
    client = Client.merge_diff(%{}, full)
    assert paint(client) == legacy_paint(socket.assigns.ash_ui_record)

    # the binding key comes from the REAL rendered payload, like a browser
    key = emitted_row_binding(paint(client), "m2")
    assert key =~ AshUi.EventBinding.key_component("m2")

    {:noreply, socket} =
      AshUi.Phoenix.runtime_handle_event(
        "ash_ui:dispatch",
        %{"binding" => key},
        socket
      )

    # the row's own action ran against live state
    assert socket.assigns.ash_ui_record.selected_id == "m2"
    assert socket.assigns[:ash_ui_errors] in [nil, []]

    # the changed set is precise and the wire diff is minimal + byte-exact
    changed = socket.assigns.ash_ui_changed
    assert MapSet.size(changed) == 1

    {diff, _prints} = render(socket, prints)
    client = Client.merge_diff(client, diff)
    assert paint(client) == legacy_paint(socket.assigns.ash_ui_record)
    assert paint(client) =~ "m2"

    flat = diff |> Map.drop([:s]) |> inspect()
    refute flat =~ "one", "row content must not re-ship on a scalar change: #{inspect(diff)}"
  end

  test "browser dispatch emits structured server action timing" do
    test_pid = self()
    handler = "ash-ui-action-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:ash_ui, :phoenix, :action],
        fn event, measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    socket = mount_socket([%{row_id: "m1", label: "one"}])
    {full, _prints} = render(socket, nil)
    key = emitted_row_binding(paint(Client.merge_diff(%{}, full)), "m1")

    assert {:noreply, updated} =
             AshUi.Phoenix.runtime_handle_event(
               "ash_ui:dispatch:" <> key,
               %{},
               socket
             )

    assert updated.assigns.ash_ui_record.selected_id == "m1"

    assert_receive {[:ash_ui, :phoenix, :action], %{duration: duration},
                    %{
                      action: :select,
                      adapter: :phoenix,
                      outcome: :ok,
                      resource: Page,
                      session_id: session_id
                    }}

    assert duration >= 0
    assert session_id == socket.assigns.ash_ui_session_id
  end

  test "binding encoded in the LiveView event name dispatches without phx-value params" do
    socket = mount_socket([%{row_id: "m1", label: "one"}])
    {full, _prints} = render(socket, nil)
    key = emitted_row_binding(paint(Client.merge_diff(%{}, full)), "m1")

    {:noreply, socket} =
      AshUi.Phoenix.runtime_handle_event(
        "ash_ui:dispatch:" <> key,
        %{},
        socket
      )

    assert socket.assigns.ash_ui_record.selected_id == "m1"
    assert socket.assigns[:ash_ui_errors] in [nil, []]
  end

  test "browser transport metadata is excluded from typed action input" do
    socket = mount_socket([%{row_id: "m1", label: "one"}])
    {full, _prints} = render(socket, nil)
    key = emitted_row_binding(paint(Client.merge_diff(%{}, full)), "m1")

    {:noreply, socket} =
      AshUi.Phoenix.runtime_handle_event(
        "ash_ui:dispatch:" <> key,
        %{"_target" => ["selected_id"], "value" => "transport-only"},
        socket
      )

    assert socket.assigns.ash_ui_record.selected_id == "m1"
    assert socket.assigns[:ash_ui_errors] in [nil, []]
  end

  test "an embedded child event runs the child action as one parent update" do
    record =
      Ash.Seed.seed!(EmbeddedPage, %{
        session_id: Ash.UUID.generate(),
        toggle: %EmbeddedToggle{name: "demo", enabled?: false}
      })

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        ash_ui_resource: EmbeddedPage,
        ash_ui_view: :view,
        ash_ui_tables: %{
          {EmbeddedPage, :view, AshUi.Phoenix.RenderTarget} =>
            Compiler.table(EmbeddedPage, target: AshUi.Phoenix.RenderTarget)
        },
        ash_ui_session_id: record.session_id,
        ash_ui_actor: nil,
        ash_ui_record: record,
        ash_ui_changed: :all,
        ash_ui_params: %{},
        ash_ui_errors: [
          %Ash.Error.Changes.InvalidChanges{message: "stale child error"}
        ]
      }
    }

    {full, _prints} = render(socket, nil)
    html = paint(Client.merge_diff(%{}, full))
    [_, event] = Regex.run(~r/phx-click="(ash_ui:dispatch:[^"]+)"/, html)

    assert {:noreply, socket} =
             AshUi.Phoenix.runtime_handle_event(event, %{}, socket)

    assert socket.assigns.ash_ui_record.toggle.enabled?
    assert socket.assigns.ash_ui_errors == []
  end

  test "a store child inside each invalidates only its keyed entry" do
    record =
      Ash.Seed.seed!(StoreChildPage, %{
        session_id: Ash.UUID.generate(),
        rows: [struct(Row, row_id: "r1", label: "one"), struct(Row, row_id: "r2", label: "two")]
      })

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        ash_ui_resource: StoreChildPage,
        ash_ui_view: :view,
        ash_ui_tables: %{
          {StoreChildPage, :view, AshUi.Phoenix.RenderTarget} =>
            Compiler.table(StoreChildPage, target: AshUi.Phoenix.RenderTarget)
        },
        ash_ui_session_id: record.session_id,
        ash_ui_actor: nil,
        ash_ui_record: record,
        ash_ui_changed: :all,
        ash_ui_params: %{}
      }
    }

    {full, prints} = render(socket, nil)
    client = Client.merge_diff(%{}, full)
    html = paint(client)
    assert html == store_child_paint(record)

    row_key = AshUi.EventBinding.key_component("r2")

    binding =
      ~r/phx-click="ash_ui:dispatch:([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.find(&String.starts_with?(&1, row_key <> "."))

    assert is_binary(binding)

    assert {:noreply, socket} =
             AshUi.Phoenix.runtime_handle_event(
               "ash_ui:dispatch:" <> binding,
               %{},
               socket
             )

    assert [%{enabled?: true}] =
             StoreToggle
             |> Ash.read!(authorize?: false, domain: AshUi.AshDomainFallback)
             |> Enum.filter(&(&1.session_id == record.session_id and &1.row_id == "r2"))

    assert Enum.any?(socket.assigns.ash_ui_changed, fn
             {:entry, _addr, ^row_key} -> true
             _other -> false
           end)

    {diff, _prints} = render(socket, prints)
    client = Client.merge_diff(client, diff)
    html = paint(client)

    assert html == store_child_paint(socket.assigns.ash_ui_record)
    assert html =~ "r1:false"
    assert html =~ "r2:true"
  end

  test "a failing action SURFACES as page error state and changes nothing" do
    socket = mount_socket([%{row_id: "forbidden", label: "nope"}])
    {full, _prints} = render(socket, nil)
    key = emitted_row_binding(paint(Client.merge_diff(%{}, full)), "forbidden")

    {:noreply, socket} =
      AshUi.Phoenix.runtime_handle_event(
        "ash_ui:dispatch",
        %{"binding" => key},
        socket
      )

    assert socket.assigns.ash_ui_record.selected_id == "none"
    assert [_error | _rest] = socket.assigns[:ash_ui_errors]
  end

  test "stale and garbage keys reject without state change" do
    socket = mount_socket([%{row_id: "m1", label: "one"}])

    for key <- ["zzz.click", "gone.v-1-0-x-0.click", ""] do
      {:noreply, after_socket} =
        AshUi.Phoenix.runtime_handle_event(
          "ash_ui:dispatch",
          %{"binding" => key},
          socket
        )

      assert after_socket.assigns.ash_ui_record.selected_id == "none"
    end
  end

  test "a client-named undeclared action is an unknown target and never executes" do
    socket = mount_socket([%{row_id: "m1", label: "one"}])

    {:noreply, rejected} =
      AshUi.Phoenix.runtime_handle_event(
        "ash_ui:dispatch",
        %{"action" => "maintenance"},
        socket
      )

    assert rejected.assigns.ash_ui_record.selected_id == "none"
    assert [_unknown_target | _rest] = rejected.assigns.ash_ui_errors
  end

  test "the reload path re-renders from row truth" do
    socket = mount_socket([%{row_id: "m1", label: "one"}])
    {full, prints} = render(socket, nil)
    client = Client.merge_diff(%{}, full)

    # out-of-band change (another writer), then any info message
    socket.assigns.ash_ui_record
    |> Ash.Changeset.for_update(:select, %{id: "m1"},
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)

    {:noreply, socket} =
      AshUi.Phoenix.runtime_handle_info(
        {:ash_ui_notification, make_ref(), %{}},
        socket
      )

    assert socket.assigns.ash_ui_record.selected_id == "m1"

    {diff, _} = render(socket, prints)
    client = Client.merge_diff(client, diff)
    assert paint(client) == legacy_paint(socket.assigns.ash_ui_record)
    assert paint(client) =~ "m1"
  end

  test "already-queued notification hints reload as one batch" do
    socket = mount_socket([%{row_id: "m1", label: "one"}])
    test_pid = self()
    handler = "notification-batch-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:ash_ui, :phoenix, :notification, :reload],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:notification_reload, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    socket.assigns.ash_ui_record
    |> Ash.Changeset.for_update(:select, %{id: "m1"},
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)

    second = {:ash_ui_notification, make_ref(), %{}}
    send(self(), second)

    assert {:noreply, reloaded} =
             AshUi.Phoenix.runtime_handle_info(
               {:ash_ui_notification, make_ref(), %{}},
               socket
             )

    assert reloaded.assigns.ash_ui_record.selected_id == "m1"

    assert_receive {:notification_reload, %{duration: duration},
                    %{notification_count: 2, reload_scope: :root}}

    assert duration >= 0
    refute_receive ^second
  end

  test "a late follow-up notification sharing a completed dispatch ref still reloads" do
    socket = mount_socket([%{row_id: "m1", label: "one"}])
    dispatch_ref = make_ref()

    socket.assigns.ash_ui_record
    |> Ash.Changeset.for_update(:select, %{id: "m1"},
      domain: AshUi.AshDomainFallback,
      authorize?: false,
      context: %{shared: %{ash_ui_dispatch_ref: dispatch_ref}}
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)

    socket =
      Phoenix.Component.assign(
        socket,
        :ash_ui_completed_dispatch_refs,
        [dispatch_ref]
      )

    event = %{
      notification: %{
        changeset: %{context: %{shared: %{ash_ui_dispatch_ref: dispatch_ref}}}
      }
    }

    {:noreply, reloaded} =
      AshUi.Phoenix.runtime_handle_info(
        {:ash_ui_notification, make_ref(), event},
        socket
      )

    assert reloaded.assigns.ash_ui_record.selected_id == "m1"
  end

  test "unrelated info messages do not reload AshUi state" do
    socket = mount_socket([%{row_id: "m1", label: "one"}])

    socket.assigns.ash_ui_record
    |> Ash.Changeset.for_update(:select, %{id: "m1"},
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)

    {:noreply, unchanged} = AshUi.Phoenix.runtime_handle_info(:host_message, socket)
    assert unchanged.assigns.ash_ui_record.selected_id == "none"
  end

  test "notification reload failures surface as page errors" do
    socket = mount_socket([%{row_id: "m1", label: "one"}])

    socket.assigns.ash_ui_record
    |> Ash.Changeset.for_destroy(:destroy, %{},
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.destroy!(domain: AshUi.AshDomainFallback)

    {:noreply, failed} =
      AshUi.Phoenix.runtime_handle_info(
        {:ash_ui_notification, make_ref(), %{}},
        socket
      )

    assert [_error | _rest] = failed.assigns[:ash_ui_errors]
  end
end
