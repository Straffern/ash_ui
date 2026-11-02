defmodule AshUi.Datastar.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: AshUi.Datastar.TaskSupervisor},
      AshUi.Datastar.Store
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: AshUi.Datastar.Supervisor
    )
  end
end
