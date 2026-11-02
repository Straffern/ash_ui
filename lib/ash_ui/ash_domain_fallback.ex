defmodule AshUi.AshDomainFallback do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered?(true)
  end

  @spec ensure!(module()) :: module() | nil
  def ensure!(resource_module) when is_atom(resource_module) do
    Ash.Resource.Info.domain(resource_module) || __MODULE__
  end
end
