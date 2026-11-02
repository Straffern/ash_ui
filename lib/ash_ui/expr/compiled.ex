defmodule AshUi.Expr.Compiled do
  @moduledoc false

  alias AshUi.Expr.Eval
  alias AshUi.Expr.Scope

  defstruct [:source, :ir, deps: []]

  @type dep :: {atom(), term()}
  @type t :: %__MODULE__{source: String.t() | nil, ir: term(), deps: [dep()]}

  def eval(%__MODULE__{ir: ir}, %Scope{} = scope), do: Eval.eval(ir, scope)
end
