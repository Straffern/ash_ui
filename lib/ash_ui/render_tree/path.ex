defmodule AshUi.RenderTree.Path do
  @moduledoc """
  Render-tree node addressing: keyed nodes use `{:key, key}` segments,
  unkeyed nodes match positionally with `{:index, index}` segments. These
  paths are the stable addresses the patch ops target and the id scheme the
  HTML renderer and binding collector already emit.
  """

  @type path :: [term()]

  @spec root_path(term()) :: path()
  def root_path(nodes) when is_list(nodes), do: []
  def root_path(nil), do: []
  def root_path(node), do: [node_path_segment(node, 0)]

  @spec child_path(path(), term(), non_neg_integer()) :: path()
  def child_path(parent_path, node, index), do: parent_path ++ [node_path_segment(node, index)]

  @spec node_path_segment(term(), non_neg_integer()) :: term()
  def node_path_segment(node, index) do
    case node_key(node) do
      nil -> {:index, index}
      key -> {:key, key}
    end
  end

  defp node_key(%{key: key}), do: key
  defp node_key(_other), do: nil
end
