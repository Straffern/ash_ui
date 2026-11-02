defmodule AshUi.Phoenix.Telemetry do
  @moduledoc false

  use Supervisor

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    children = [
      {:telemetry_poller,
       measurements: Keyword.get(opts, :measurements, []),
       period: Keyword.get(opts, :period, 10_000)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
