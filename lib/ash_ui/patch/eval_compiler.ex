defmodule AshUi.Patch.EvalCompiler do
  @moduledoc false

  @spec hash(term()) :: non_neg_integer()
  def hash(ir), do: :erlang.phash2({:bp_eval, ir})

  @doc false
  def function_name(hash), do: String.to_atom("__bp_eval_#{hash}__")

  @spec compile(term()) :: {:ok, Macro.t()} | :error
  def compile(ir) do
    {:ok,
     quote do
       AshUi.Expr.Eval.eval!(unquote(Macro.escape(ir)), scope)
     end}
  rescue
    _error in ArgumentError -> :error
  end

  @doc false
  def clause(ir) do
    hash = hash(ir)
    function = function_name(hash)

    case compile(ir) do
      {:ok, body} ->
        {:ok, hash,
         quote do
           def __bp_eval__(unquote(hash), record, args, item_bindings, index_bindings) do
             scope =
               AshUi.Expr.Scope.new(record, args,
                 item_bindings: item_bindings,
                 index_bindings: index_bindings
               )

             unquote(body)
           end

           @doc false
           def unquote(function)(scope), do: unquote(body)
         end}

      :error ->
        :error
    end
  end
end
