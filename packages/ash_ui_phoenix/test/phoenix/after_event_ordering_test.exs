defmodule AshUi.Phoenix.AfterEventOrderingTest do
  use ExUnit.Case, async: false

  alias AshUi.Patch.Compiler

  @gate_table :ash_ui_after_event_ordering_gate

  defmodule Row do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule BlockingRows do
    @moduledoc false
    use Ash.Resource.ManualRelationship

    @impl true
    def load(records, _opts, _context) do
      case :ets.lookup(:ash_ui_after_event_ordering_gate, :block) do
        [{:block, test_pid}] ->
          send(test_pid, {:dependent_reload_started, self()})

          receive do
            :release_dependent_reload -> :ok
          end

        [] ->
          :ok
      end

      {:ok, Map.new(records, fn record -> {Map.take(record, [:session_id]), []} end)}
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
      private?(false)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:query, :string, allow_nil?: false, default: "initial", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :rows, AshUi.Phoenix.AfterEventOrderingTest.Row do
        no_attributes?(true)

        manual({AshUi.Phoenix.AfterEventOrderingTest.BlockingRows, depends_on: [:query]})
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [part: :after_event_ordering_root], [
            button(
              :change_query,
              [
                part: :after_event_ordering_button,
                on_click: :change_query,
                action_input: %{query: "fresh action state"}
              ],
              [text(query)]
            ),
            list(:rows, [part: :after_event_ordering_rows], [
              each(rows, :row, [key: row.id], [
                item(:row, [part: :after_event_ordering_row], [text(row.label)])
              ])
            ])
          ])
        )
      )
    end

    actions do
      defaults([:read])

      create(:mount)

      update :change_query do
        require_atomic?(false)
        argument(:query, :string, allow_nil?: false)
        change(set_attribute(:query, arg(:query)))
      end
    end
  end

  setup do
    if :ets.whereis(@gate_table) == :undefined do
      :ets.new(@gate_table, [:named_table, :public, :set])
    end

    :ets.delete_all_objects(@gate_table)
    :ok
  end

  test "after_event sees post-action state before a dependent reload completes" do
    test_pid = self()

    after_event = fn action, _payload, socket, record ->
      send(test_pid, {:after_event, action, record.query})
      Phoenix.Component.assign(socket, :after_event_query, record.query)
    end

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}, private: %{}}

    assert {:ok, socket} =
             AshUi.Phoenix.mount(
               Page,
               %{},
               %{"ash_ui_session_id" => Ash.UUID.generate()},
               socket,
               after_event: after_event,
               otp_app: :ash_ui_phoenix
             )

    table = Compiler.table(Page, :view, target: AshUi.Phoenix.RenderTarget)
    [address] = Map.keys(table.event_elements)
    binding = Compiler.addr_component(address)

    :ets.insert(@gate_table, {:block, test_pid})

    task =
      Task.async(fn ->
        AshUi.Phoenix.runtime_handle_event(
          "ash_ui:dispatch:" <> binding <> ".click",
          %{},
          socket
        )
      end)

    try do
      assert_receive {:after_event, :change_query, "fresh action state"}
      assert_receive {:dependent_reload_started, reload_pid}

      send(reload_pid, :release_dependent_reload)

      assert {:noreply, refreshed} = Task.await(task)
      assert refreshed.assigns.ash_ui_record.query == "fresh action state"
      assert refreshed.assigns.after_event_query == "fresh action state"
    after
      send(task.pid, :release_dependent_reload)

      if Process.alive?(task.pid) do
        Task.shutdown(task, :brutal_kill)
      end
    end
  end

  test "static mount handoff transfers session-row ownership to the connected transport" do
    session_id = Ash.UUID.generate()
    AshUi.Notification.MatchIndex.reset()

    static_record =
      Task.async(fn ->
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}, private: %{}}

        {:ok, mounted} =
          AshUi.Phoenix.mount(
            Page,
            %{},
            %{"ash_ui_session_id" => session_id},
            socket,
            otp_app: :ash_ui_phoenix
          )

        mounted.assigns.ash_ui_record
      end)
      |> Task.await()

    # The disconnected HTTP renderer has exited. Its handoff row must remain
    # available because that process never owns the browser session.
    Process.sleep(20)

    assert %Page{session_id: ^session_id} =
             Ash.get!(Page, session_id,
               domain: AshUi.AshDomainFallback,
               authorize?: false
             )

    Process.put(:"$callers", [self()])

    live_socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}},
      private: %{}
    }

    assert {:ok, mounted} =
             AshUi.Phoenix.mount(
               Page,
               %{},
               %{"ash_ui_session_id" => session_id},
               live_socket,
               otp_app: :ash_ui_phoenix
             )

    assert mounted.assigns.ash_ui_record == static_record

    assert [{_ref, %{attrs: []}}] =
             AshUi.Notification.MatchIndex.subs_for(
               AshUi.Phoenix.AfterEventOrderingTest.Row
             )

    session_rows =
      AshUi.Notification.MatchIndex
      |> :sys.get_state()
      |> Map.fetch!(:session_rows)
      |> Map.fetch!(self())

    assert MapSet.member?(session_rows, {Page, session_id, nil})
  end

  test "a connected Bridge and its fold die with the client transport and its row is reclaimed" do
    session_id = Ash.UUID.generate()
    AshUi.Notification.MatchIndex.reset()
    parent = self()
    transport = spawn(fn -> receive do: (:close -> :ok) end)

    bridge =
      spawn(fn ->
        fold = spawn_link(fn -> receive do: (:release -> :ok) end)
        Process.put(:"$callers", [transport])

        socket = %Phoenix.LiveView.Socket{
          transport_pid: transport,
          assigns: %{__changed__: %{}},
          private: %{}
        }

        {:ok, mounted} =
          AshUi.Phoenix.mount(
            Page,
            %{},
            %{"ash_ui_session_id" => session_id},
            socket,
            otp_app: :ash_ui_phoenix
          )

        send(parent, {:bridge_mounted, self(), fold, mounted.assigns.ash_ui_record})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:bridge_mounted, ^bridge, fold, %Page{session_id: ^session_id}}, 5_000
    bridge_ref = Process.monitor(bridge)
    fold_ref = Process.monitor(fold)

    Process.exit(transport, :kill)

    assert_receive {:DOWN, ^bridge_ref, :process, ^bridge, :killed}, 5_000
    assert_receive {:DOWN, ^fold_ref, :process, ^fold, :killed}, 5_000

    assert_eventually(fn ->
      Page
      |> Ash.read!(domain: AshUi.AshDomainFallback, authorize?: false)
      |> Enum.any?(&(&1.session_id == session_id))
      |> Kernel.not()
    end)
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
