defmodule AshUi.Datastar.Store do
  @moduledoc false
  use GenServer

  alias __MODULE__.Session

  @transaction_key {__MODULE__, :transaction}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def get(session_id) do
    case transaction_owner(session_id) do
      {:ok, owner} -> owner.value
      :outside -> session_call(session_id, :get, nil)
    end
  end

  def put(session_id, state) do
    case transaction_owner(session_id) do
      {:ok, owner} ->
        put_transaction_owner(session_id, %{owner | value: state})
        :ok

      :outside ->
        session_id
        |> ensure_session()
        |> GenServer.call({:put, state}, :infinity)
    end
  end

  def delete(session_id) do
    case transaction_owner(session_id) do
      {:ok, owner} ->
        put_transaction_owner(session_id, %{owner | value: nil})
        :ok

      :outside ->
        GenServer.call(__MODULE__, {:delete, session_id}, :infinity)
    end
  end

  @doc false
  def attach(session_id, client_id, pid)
      when is_binary(session_id) and is_pid(pid) do
    case transaction_owner(session_id) do
      {:ok, owner} ->
        {first?, owner} = Session.attach(owner, client_id, pid)
        put_transaction_owner(session_id, owner)
        first?

      :outside ->
        session_id
        |> ensure_session()
        |> GenServer.call({:attach, client_id, pid}, :infinity)
    end
  end

  @doc false
  def detach(session_id, client_id, pid)
      when is_binary(session_id) and is_pid(pid) do
    case transaction_owner(session_id) do
      {:ok, owner} ->
        {detached?, owner} = Session.detach(owner, client_id, pid)
        put_transaction_owner(session_id, owner)
        detached?

      :outside ->
        session_call(session_id, {:detach, client_id, pid}, false)
    end
  end

  @doc false
  def broadcast(session_id, events, opts \\ [])
      when is_binary(session_id) and is_list(events) do
    except_client_id = Keyword.get(opts, :except)

    case transaction_owner(session_id) do
      {:ok, owner} ->
        Session.broadcast(owner, events, except_client_id)

      :outside ->
        session_call(session_id, {:broadcast, events, except_client_id}, :ok)
    end
  end

  @doc false
  def configure_notifications(session_id, base_ref, refs, handler)
      when is_binary(session_id) and is_struct(refs, MapSet) do
    case transaction_owner(session_id) do
      {:ok, owner} ->
        owner = Session.configure_notifications(owner, base_ref, refs, handler)
        put_transaction_owner(session_id, owner)
        :ok

      :outside ->
        session_call(
          session_id,
          {:configure_notifications, base_ref, refs, handler},
          :missing_session
        )
    end
  end

  @doc false
  def notification_info(session_id) when is_binary(session_id) do
    case transaction_owner(session_id) do
      {:ok, owner} -> Session.notification_info(owner)
      :outside -> session_call(session_id, :notification_info, nil)
    end
  end

  @doc false
  def put_notification_refs(session_id, refs)
      when is_binary(session_id) and is_struct(refs, MapSet) do
    case transaction_owner(session_id) do
      {:ok, owner} ->
        owner = Session.put_notification_refs(owner, refs)
        put_transaction_owner(session_id, owner)
        :ok

      :outside ->
        session_call(session_id, {:put_notification_refs, refs}, :missing_session)
    end
  end

  @doc false
  def client_count(session_id) when is_binary(session_id) do
    case transaction_owner(session_id) do
      {:ok, owner} -> map_size(owner.clients)
      :outside -> session_call(session_id, :client_count, 0)
    end
  end

  # Run the whole request-side state transition on the process that owns the
  # session. Large records and differential snapshots consequently stay on one
  # heap across dispatches, just like LiveView socket state, instead of being
  # copied out of and back into a central GenServer for every HTTP request.
  # The session process is also the dispatch-cycle barrier used by the update
  # stream: a notification transaction queued during a POST begins only after
  # that POST has persisted its final state.
  def transaction(session_id, fun) when is_binary(session_id) and is_function(fun, 0) do
    # The session process is long-lived and unrelated to the request process,
    # so it does not inherit the request's `$callers` chain the way a Task or a
    # LiveView child would. Carry it across explicitly: request-scoped work
    # (Ecto SQL Sandbox ownership, Ash context transfer) resolves through
    # `$callers`, and the dispatch Task spawned inside the transaction copies it
    # onward. Harmless in production (no sandbox); required under async tests.
    callers = [self() | Process.get(:"$callers", [])]

    session_id
    |> ensure_session()
    |> GenServer.call({:transaction, session_id, fun, callers}, :infinity)
    |> case do
      {:ok, result} -> result
      {:raise, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{sessions: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:ensure, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      pid when is_pid(pid) ->
        {:reply, pid, state}

      nil ->
        {:ok, pid} = Session.start_link(session_id)
        monitor = Process.monitor(pid)

        {:reply, pid,
         %{
           state
           | sessions: Map.put(state.sessions, session_id, pid),
             monitors: Map.put(state.monitors, monitor, session_id)
         }}
    end
  end

  def handle_call({:lookup, session_id}, _from, state),
    do: {:reply, Map.get(state.sessions, session_id), state}

  def handle_call({:delete, session_id}, _from, state) do
    {pid, sessions} = Map.pop(state.sessions, session_id)

    if is_pid(pid), do: GenServer.stop(pid, :normal, :infinity)

    monitors =
      Map.reject(state.monitors, fn {_monitor, monitored_session_id} ->
        monitored_session_id == session_id
      end)

    {:reply, :ok, %{state | sessions: sessions, monitors: monitors}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, monitors} ->
        {:noreply, %{state | monitors: monitors}}

      {session_id, monitors} ->
        {:noreply,
         %{
           state
           | sessions: Map.delete(state.sessions, session_id),
             monitors: monitors
         }}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp ensure_session(session_id),
    do: GenServer.call(__MODULE__, {:ensure, session_id}, :infinity)

  defp session_call(session_id, message, default) do
    case GenServer.call(__MODULE__, {:lookup, session_id}, :infinity) do
      pid when is_pid(pid) -> GenServer.call(pid, message, :infinity)
      nil -> default
    end
  end

  defp transaction_owner(session_id) do
    case Process.get(@transaction_key) do
      {^session_id, owner} -> {:ok, owner}
      _outside -> :outside
    end
  end

  defp put_transaction_owner(session_id, owner),
    do: Process.put(@transaction_key, {session_id, owner})

  defmodule Session do
    @moduledoc false
    use GenServer

    require Logger

    @transaction_key {AshUi.Datastar.Store, :transaction}

    # Hibernate only after the session has been IDLE, never per transaction:
    # hibernation full-sweeps and compacts the session heap, and doing that
    # on every dispatch is a full GC of the whole record + live snapshot per
    # keystroke (~2ms at 10k rows). The idle timeout keeps the memory
    # property for abandoned sessions without taxing active ones.
    @idle_hibernate_ms 15_000

    defmodule State do
      @moduledoc false
      defstruct [:session_id, :value, :notification, clients: %{}, monitors: %{}]
    end

    def start_link(session_id), do: GenServer.start_link(__MODULE__, session_id)

    @impl true
    def init(session_id), do: {:ok, %State{session_id: session_id}}

    @impl true
    def handle_call(:get, _from, state),
      do: {:reply, state.value, state, @idle_hibernate_ms}

    def handle_call({:put, value}, _from, state),
      do: {:reply, :ok, %{state | value: value}, @idle_hibernate_ms}

    def handle_call({:attach, client_id, pid}, _from, state) do
      {first?, state} = attach(state, client_id, pid)
      {:reply, first?, state, @idle_hibernate_ms}
    end

    def handle_call({:detach, client_id, pid}, _from, state) do
      {detached?, state} = detach(state, client_id, pid)
      {:reply, detached?, state, @idle_hibernate_ms}
    end

    def handle_call({:broadcast, events, except_client_id}, _from, state) do
      :ok = broadcast(state, events, except_client_id)
      {:reply, :ok, state, @idle_hibernate_ms}
    end

    def handle_call(
          {:configure_notifications, base_ref, refs, handler},
          _from,
          state
        ) do
      state = configure_notifications(state, base_ref, refs, handler)
      {:reply, :ok, state, @idle_hibernate_ms}
    end

    def handle_call(:notification_info, _from, state),
      do: {:reply, notification_info(state), state, @idle_hibernate_ms}

    def handle_call({:put_notification_refs, refs}, _from, state) do
      state = put_notification_refs(state, refs)
      {:reply, :ok, state, @idle_hibernate_ms}
    end

    def handle_call(:client_count, _from, state),
      do: {:reply, map_size(state.clients), state, @idle_hibernate_ms}

    def handle_call({:transaction, session_id, fun, callers}, _from, state) do
      case run_transaction(state, session_id, fun, callers) do
        {:ok, result, next_state} ->
          {:reply, {:ok, result}, next_state, @idle_hibernate_ms}

        {:raise, kind, reason, stacktrace, unchanged_state} ->
          {:reply, {:raise, kind, reason, stacktrace}, unchanged_state, @idle_hibernate_ms}
      end
    end

    @impl true
    def handle_info(
          {:ash_ui_notification, ref, _event},
          %State{notification: %{refs: refs} = notification} = state
        ) do
      if MapSet.member?(refs, ref) do
        notification_refs = drain_notification_refs(refs, MapSet.new([ref]), [])

        result =
          run_transaction(
            state,
            state.session_id,
            fn ->
              {module, function, args} = notification.handler
              apply(module, function, args ++ [notification_refs])
            end,
            notification.callers
          )

        case result do
          {:ok, {:ok, events, updated_refs}, next_state} ->
            next_state = put_notification_refs(next_state, updated_refs)
            :ok = broadcast(next_state, events, nil)
            {:noreply, next_state, @idle_hibernate_ms}

          {:ok, {:error, reason}, next_state} ->
            Logger.warning("AshUi Datastar notification reload failed: #{inspect(reason)}")

            {:noreply, next_state, @idle_hibernate_ms}

          {:raise, kind, reason, stacktrace, unchanged_state} ->
            Logger.warning(
              "AshUi Datastar notification reload failed: " <>
                Exception.format(kind, reason, stacktrace)
            )

            {:noreply, unchanged_state, @idle_hibernate_ms}
        end
      else
        {:noreply, state, @idle_hibernate_ms}
      end
    end

    def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
      {:noreply, disconnect_monitor(state, monitor, pid), @idle_hibernate_ms}
    end

    def handle_info(:timeout, state), do: {:noreply, state, :hibernate}

    def handle_info(_message, state), do: {:noreply, state, @idle_hibernate_ms}

    @impl true
    def terminate(_reason, state) do
      cleanup_notifications(state)
      :ok
    end

    @doc false
    def attach(%State{} = state, client_id, pid) when is_pid(pid) do
      first? = map_size(state.clients) == 0

      notification =
        case state.notification do
          nil -> nil
          notification -> %{notification | callers: Process.get(:"$callers", [])}
        end

      case Map.get(state.clients, client_id) do
        %{pid: ^pid} ->
          {first?, %{state | notification: notification}}

        existing_client ->
          state =
            case existing_client do
              %{monitor: old_monitor} ->
                Process.demonitor(old_monitor, [:flush])

                %{
                  state
                  | clients: Map.delete(state.clients, client_id),
                    monitors: Map.delete(state.monitors, old_monitor)
                }

              nil ->
                state
            end

          monitor = Process.monitor(pid)

          {first?,
           %{
             state
             | clients: Map.put(state.clients, client_id, %{pid: pid, monitor: monitor}),
               monitors: Map.put(state.monitors, monitor, client_id),
               notification: notification
           }}
      end
    end

    @doc false
    def detach(%State{} = state, client_id, pid) when is_pid(pid) do
      case Map.get(state.clients, client_id) do
        %{pid: ^pid, monitor: monitor} ->
          Process.demonitor(monitor, [:flush])

          state = %{
            state
            | clients: Map.delete(state.clients, client_id),
              monitors: Map.delete(state.monitors, monitor)
          }

          {true, maybe_cleanup_last_client(state)}

        _other_client_or_connection ->
          {false, state}
      end
    end

    @doc false
    def broadcast(%State{} = state, events, except_client_id) when is_list(events) do
      Enum.each(state.clients, fn
        {^except_client_id, _client} ->
          :ok

        {_client_id, %{pid: pid}} ->
          send(pid, {:ash_ui_datastar_events, events})
      end)

      :ok
    end

    @doc false
    def configure_notifications(%State{} = state, base_ref, refs, handler) do
      %{
        state
        | notification: %{
            base_ref: base_ref,
            refs: refs,
            handler: handler,
            callers: Process.get(:"$callers", [])
          }
      }
    end

    @doc false
    def notification_info(%State{notification: nil}), do: nil

    def notification_info(%State{notification: notification}),
      do: Map.take(notification, [:base_ref, :refs])

    @doc false
    def put_notification_refs(%State{notification: nil} = state, _refs), do: state

    def put_notification_refs(%State{} = state, refs),
      do: %{state | notification: %{state.notification | refs: refs}}

    defp disconnect_monitor(state, monitor, pid) do
      case Map.pop(state.monitors, monitor) do
        {nil, monitors} ->
          %{state | monitors: monitors}

        {client_id, monitors} ->
          clients =
            case Map.get(state.clients, client_id) do
              %{pid: ^pid, monitor: ^monitor} -> Map.delete(state.clients, client_id)
              _new_connection -> state.clients
            end

          maybe_cleanup_last_client(%{state | clients: clients, monitors: monitors})
      end
    end

    defp maybe_cleanup_last_client(%State{clients: clients} = state)
         when map_size(clients) == 0,
         do: cleanup_notifications(state)

    defp maybe_cleanup_last_client(state), do: state

    defp cleanup_notifications(%State{notification: nil} = state), do: state

    defp cleanup_notifications(%State{notification: %{refs: refs}} = state) do
      Enum.each(refs, &AshUi.Notification.MatchIndex.deregister/1)
      %{state | notification: nil}
    end

    defp run_transaction(state, session_id, fun, callers) do
      Process.put(@transaction_key, {session_id, state})
      previous_callers = Process.get(:"$callers")
      Process.put(:"$callers", callers)

      try do
        result = fun.()
        {^session_id, next_state} = Process.get(@transaction_key)
        {:ok, result, next_state}
      catch
        kind, reason ->
          {:raise, kind, reason, __STACKTRACE__, state}
      after
        Process.delete(@transaction_key)
        restore_callers(previous_callers)
      end
    end

    defp drain_notification_refs(refs, found, deferred) do
      receive do
        {:ash_ui_notification, ref, _event} = message ->
          if MapSet.member?(refs, ref) do
            drain_notification_refs(refs, MapSet.put(found, ref), deferred)
          else
            drain_notification_refs(refs, found, [message | deferred])
          end
      after
        0 ->
          deferred |> Enum.reverse() |> Enum.each(&send(self(), &1))
          found
      end
    end

    defp restore_callers(nil), do: Process.delete(:"$callers")
    defp restore_callers(callers), do: Process.put(:"$callers", callers)
  end
end
