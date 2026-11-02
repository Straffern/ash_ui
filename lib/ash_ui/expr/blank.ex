defmodule AshUi.Expr.Blank do
  @moduledoc false

  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(%Ash.NotLoaded{}), do: true
  def blank?(_value), do: false

  @spec present?(term()) :: boolean()
  def present?(value), do: not blank?(value)

  @spec empty?(term()) :: boolean()
  def empty?([]), do: true
  def empty?(%{kind: :fragment, children: []}), do: true
  def empty?(%AshUi.RenderTree.Fragment{children: []}), do: true
  def empty?(value), do: blank?(value)
end
