defmodule AshUi.RenderTarget.Static do
  @moduledoc "The default render target, preserving AshUi's neutral DOM vocabulary."

  use AshUi.RenderTarget

  @impl AshUi.RenderTarget
  def attr_name(name), do: name

  @impl AshUi.RenderTarget
  def finalize_tree(tree), do: tree
end
