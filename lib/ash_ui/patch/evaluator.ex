defmodule AshUi.Patch.Evaluator do
  @moduledoc false

  alias AshUi.Expr.Compiled
  alias AshUi.Expr.Scope
  alias AshUi.Patch.EvalCompiler

  @type t ::
          {:expr, Compiled.t()}
          | {:static, term()}
          | {:assigns, module(), module(), map()}
          | {:element_attrs, map()}
          | (Scope.t() -> term())

  @spec compile(term(), module() | nil) :: t()
  def compile(%Compiled{ir: ir} = expression, resource) do
    function = ir |> EvalCompiler.hash() |> EvalCompiler.function_name()

    if is_atom(resource) and not is_nil(resource) and Code.ensure_loaded?(resource) and
         function_exported?(resource, function, 1) do
      Function.capture(resource, function, 1)
    else
      {:expr, expression}
    end
  end

  def compile(value, _resource), do: {:static, value}

  @spec eval(t(), Scope.t()) :: term()
  def eval(evaluator, %Scope{} = scope) when is_function(evaluator, 1), do: evaluator.(scope)

  def eval({:expr, expression}, %Scope{} = scope),
    do: AshUi.Expr.Eval.eval!(expression, scope)

  def eval({:static, value}, %Scope{}), do: value

  def eval({:assigns, resource, target, evaluators}, %Scope{} = scope) do
    eval_assigns(resource, target, evaluators, scope, [])
  end

  def eval({:element_attrs, descriptor}, %Scope{} = scope) do
    AshUi.Patch.Compiler.evaluate_element_attrs(descriptor, scope)
  end

  @doc false
  def eval_component_input(
        {:assigns, resource, target, evaluators},
        %Scope{} = scope,
        direct_fragment_inputs
      ) do
    eval_assigns(resource, target, evaluators, scope, direct_fragment_inputs)
  end

  def eval_component_input(evaluator, %Scope{} = scope, _direct_fragment_inputs),
    do: eval(evaluator, scope)

  defp eval_assigns(resource, target, evaluators, scope, direct_fragment_inputs) do
    direct_fragment_inputs = Map.new(direct_fragment_inputs, &{&1, true})

    Map.new(evaluators, fn
      {key, {:fragment, _value}} when is_map_key(direct_fragment_inputs, key) ->
        # Keep child input validation/defaults intact without materializing the
        # real fragment twice. The attached skeleton supplies its actual
        # content; an empty RenderTree is the neutral valid placeholder.
        {key, []}

      {key, {:fragment, value}} ->
        {:ok, tree} =
          AshUi.Runtime.ViewRender.materialize_fragment_value(
            value,
            resource,
            scope.record,
            scope.args,
            fragment_render_opts(scope, target)
          )

        {key, tree}

      {key, evaluator} ->
        {key, eval(evaluator, scope)}
    end)
  end

  defp fragment_render_opts(scope, target) do
    errors = Map.get(scope.context, :__bp_all_errors__, scope.errors)

    [
      actor: scope.actor,
      tenant: scope.tenant,
      context: scope.context,
      item_bindings: scope.item_bindings,
      index_bindings: scope.index_bindings,
      errors: errors,
      target: target,
      __bp_all_errors__: errors,
      __bp_chain__: Map.get(scope.context, :__bp_binding_chain__, [])
    ]
  end
end
