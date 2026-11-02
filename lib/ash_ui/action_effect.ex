defmodule AshUi.ActionEffect do
  @moduledoc """
  A one-shot browser affordance emitted by a successful Ash action.

  Action effects are deliberately limited to DOM commands that cannot be
  represented as durable resource state. They are delivered by the host
  adapter after the action succeeds and are never replayed by re-rendering.
  """

  @type name :: :focus | :scroll_into_view | :select_text
  @type target :: {:id, String.t()} | {:part, String.t()}

  @enforce_keys [:name, :target]
  defstruct [:name, :target, options: %{}]

  @type t :: %__MODULE__{name: name(), target: target(), options: map()}

  @doc false
  @spec event_name(t()) :: String.t()
  def event_name(%__MODULE__{name: name}),
    do: "ash_ui:" <> (name |> Atom.to_string() |> String.replace("_", "-"))

  @doc false
  @spec payload(t()) :: map()
  def payload(%__MODULE__{target: {target_kind, target}, options: options}) do
    options
    |> Map.new()
    |> Map.put(target_kind, target)
  end
end
