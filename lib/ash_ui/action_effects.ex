defmodule AshUi.ActionEffects do
  @moduledoc """
  Declarative, one-shot DOM effects for Ash actions.

  Effects run only after a successful action and only when an AshUi host
  supplied an effect sink in the action context.
  """

  @doc "Focuses the declared DOM target once after the action succeeds."
  def focus(opts) when is_list(opts) do
    {AshUi.Changes.EmitActionEffect, Keyword.put(opts, :effect, :focus)}
  end

  @doc "Scrolls the declared DOM target into view once after the action succeeds."
  def scroll_into_view(opts) when is_list(opts) do
    {AshUi.Changes.EmitActionEffect, Keyword.put(opts, :effect, :scroll_into_view)}
  end

  @doc "Selects the text in the declared DOM target once after the action succeeds."
  def select_text(opts) when is_list(opts) do
    {AshUi.Changes.EmitActionEffect, Keyword.put(opts, :effect, :select_text)}
  end
end
