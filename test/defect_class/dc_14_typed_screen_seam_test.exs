defmodule AshUi.DefectClass.DC14TypedScreenSeamTest do
  @moduledoc """
  DC-14: the typed screen seam belonged to the deleted App/Adapter second
  model (screens, screen refs, hosted-child mounting through the Runtime
  facade). Post one-cut there is no screen seam: a page is an Ash row and
  composition is `render(Module, input)`. This gate verifies the machinery
  stays deleted.
  """
  use ExUnit.Case, async: true

  test "the App/Adapter screen machinery is absent" do
    for module <- [
          AshUi.App,
          AshUi.AppBlueprint,
          AshUi.Adapter,
          AshUi.Adapter.App,
          AshUi.Adapter.Route,
          AshUi.Adapter.ScreenRef,
          AshUi.Adapter.Session,
          AshUi.RuntimeState,
          AshUi.Runtime
        ] do
      refute Code.ensure_loaded?(module), "expected #{inspect(module)} to be deleted"
    end
  end
end
