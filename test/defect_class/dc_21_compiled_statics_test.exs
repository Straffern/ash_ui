defmodule AshUi.DefectClass.DC21CompiledStaticsTest do
  @moduledoc """
  DC-21 (inverted): the compiled-segments renderer must NOT exist. It was
  a second full renderer kept byte-equivalent to the interpreted pipeline
  by this very defect class — pure duplication. One render pipeline
  remains (`ViewRender` → `RenderTree` → `Html`); its static/live byte
  contracts are gated by DC-36 (skeleton byte-alignment) and the phoenix
  LiveRender wire gates.
  """
  use ExUnit.Case, async: true

  test "the compiled segment renderer stack does not exist" do
    refute Code.ensure_loaded?(AshUi.Runtime.CompiledRender)
    refute Code.ensure_loaded?(AshUi.StaticCompile.Segments)
    refute Code.ensure_loaded?(AshUi.CompiledView)
  end

  test "no compiled-view artifacts are persisted or readable" do
    refute function_exported?(AshUi.Compiled, :compiled_view!, 2)
    refute function_exported?(AshUi.Compiled, :compiled_views, 1)
    refute function_exported?(AshUi.StaticCompile, :compiled_views, 2)
  end
end
