defmodule AshUi.Phoenix.Presets.DaisyUI do
  @moduledoc """
  Optional AshAuthentication override preset for DaisyUI-styled auth screens.
  """

  def ash_authentication_overrides do
    [AshAuthentication.Phoenix.Overrides.DaisyUI]
  end
end
