defmodule AshUi.Application do
  @moduledoc false

  # Supervises the notification substrate: the match index (keyed ETS
  # tables + session-pid monitors). Dispatch remains node-local by
  # design (v1 is explicitly single-node; sessions reconcile by
  # reload-on-reconnect — RR-I1).

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AshUi.Notification.MatchIndex
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AshUi.Supervisor)
  end
end
