defmodule Mix.Tasks.AshUi.Digest do
  @moduledoc false

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("phx.digest", args)
  end
end
