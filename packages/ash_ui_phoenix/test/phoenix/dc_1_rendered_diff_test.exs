defmodule AshUi.Phoenix.DC1RenderedDiffTest do
  @moduledoc """
  DC-1 (inverted after the differential cutover): the tree-diffing render
  host must NOT exist. LiveView output builds from the compiled patch
  table via `AshUi.Phoenix.LiveRender`; the change source is the
  patch engine's propagation, never a previous tree.
  """
  use ExUnit.Case, async: true

  test "RenderTreeHost does not exist" do
    refute Code.ensure_loaded?(AshUi.Phoenix.RenderTreeHost)
  end

  test "RenderTree.Diff does not exist" do
    refute Code.ensure_loaded?(AshUi.RenderTree.Diff)
  end

  test "the bridge exposes no tree assigns contract" do
    refute function_exported?(AshUi.Phoenix, :render_root_tree, 1)
  end
end
