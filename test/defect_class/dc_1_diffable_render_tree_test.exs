defmodule AshUi.DefectClass.DC1DiffableRenderTreeTest do
  @moduledoc """
  DC-1 (inverted after the differential cutover): tree-vs-tree diffing must
  NOT exist. The live path is change-driven — compiled patch tables +
  propagation-derived changed sets — and a resurrected structural differ
  would silently reintroduce the whole-render-per-update model.
  """
  use ExUnit.Case, async: true

  test "RenderTree.Diff does not exist" do
    refute Code.ensure_loaded?(AshUi.RenderTree.Diff)
  end

  test "no module exposes tree-vs-tree render diffing" do
    refute function_exported?(AshUi.RenderTree, :diff, 2)
    refute Code.ensure_loaded?(AshUi.Runtime.TreeDiff)
  end

  test "the bindings-registration render flow is gone" do
    refute function_exported?(AshUi.Runtime, :render_tree_with_bindings, 4)
    refute function_exported?(AshUi.Runtime, :binding, 2)
    refute function_exported?(AshUi.Adapter, :render_with_session, 2)
    refute function_exported?(AshUi.Adapter, :render, 2)
    refute function_exported?(AshUi.Adapter, :binding, 2)
  end
end
