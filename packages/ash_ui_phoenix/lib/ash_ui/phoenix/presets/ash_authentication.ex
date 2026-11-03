# Compiled only when the optional :ash_authentication_phoenix dependency is present.
if Code.ensure_loaded?(AshAuthentication.Phoenix.Router) do
  defmodule AshUi.Phoenix.Presets.AshAuthentication do
    @moduledoc """
    Optional router preset for hosts that use AshAuthentication Phoenix routes.
    """

    defmacro __using__(_opts) do
      quote do
        use AshAuthentication.Phoenix.Router
      end
    end
  end
end
