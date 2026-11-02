defmodule AshUi.Expr do
  @moduledoc """
  Expression entry point for AshUi constructor expressions.
  """

  defmacro expr(do: body) do
    expand_expr(body, __CALLER__)
  end

  defmacro expr(body) do
    expand_expr(body, __CALLER__)
  end

  defmacro arg(name) do
    quote do
      {:_arg, unquote(name)}
    end
  end

  defmacro context(name) do
    quote do
      {:_context, unquote(name)}
    end
  end

  defmacro part_id(name) do
    quote do
      {:_part_id, unquote(name)}
    end
  end

  defmacro result() do
    quote do
      {:_result}
    end
  end

  defmacro result(name) do
    quote do
      {:_result, unquote(name)}
    end
  end

  defmacro errors() do
    quote do
      {:_errors}
    end
  end

  defmacro runtime_call(_module, _function, _args) do
    raise_runtimecall_removed!(__CALLER__)
  end

  defmacro field_errors(field) do
    quote do
      {:call, :field_errors, [unquote(field)]}
    end
  end

  defmacro field_errors(errors, field) do
    quote do
      {:call, :field_errors, [unquote(errors), unquote(field)]}
    end
  end

  defmacro path(value, segments) do
    quote do
      {:call, :path, [unquote(value), unquote(segments)]}
    end
  end

  def expand_expr_ast(body, caller) do
    expand_expr(body, caller)
  end

  def rewrite_ast(body, caller) do
    rewrite_helpers(body, caller)
  end

  def capability_marker_ast?(ast) do
    capability_marker?(ast)
  end

  def expand_inline_ast({:expr, _meta, [[do: body]]}, caller) do
    expand_expr(body, caller)
  end

  def expand_inline_ast({:expr, _meta, [body]}, caller) do
    expand_expr(body, caller)
  end

  def expand_inline_ast(other, caller), do: runtime_value_data(other, caller)

  def runtime_value_ast(value, caller) do
    runtime_value_data(value, caller)
  end

  defp rewrite_helpers(ast, caller) do
    Macro.prewalk(ast, fn
      {{:., dot_meta, [module_ast, function_name]}, call_meta, args}
      when is_atom(function_name) and is_list(args) ->
        rewritten_args = Enum.map(args, &rewrite_helpers(&1, caller))
        expanded_module = Macro.expand(module_ast, caller)

        cond do
          expanded_module == Ash.Expr ->
            {{:., dot_meta, [module_ast, function_name]}, call_meta, rewritten_args}

          args == [] and accessor_base_ast?(module_ast) ->
            {{:., dot_meta, [rewrite_helpers(module_ast, caller), function_name]}, call_meta, []}

          true ->
            raise ArgumentError,
                  "unsupported remote expr call #{inspect(expanded_module)}.#{function_name}/#{length(args)}; use native Ash expressions, AshUi constructors/accessors, stdlib calls, or Ash.CustomExpression modules"
        end

      {:^, meta, [{:context, _, [name]}]} ->
        {:^, meta, [quote(do: Ash.Expr.context(unquote(name)))]}

      {:runtime_call, _meta, [_module, _function, _args]} ->
        raise_runtimecall_removed!(caller)

      {:arg, meta, [name]} ->
        {:^, meta, [quote(do: Ash.Expr.arg(unquote(name)))]}

      {:context, meta, [name]} ->
        {:^, meta, [quote(do: Ash.Expr.context(unquote(name)))]}

      {:screen_variant, meta, []} ->
        {:^, meta, [quote(do: Ash.Expr.context(:screen_variant))]}

      {:item, meta, [name, field]} ->
        {:item, meta, [name, field]}

      {:field, meta, [name, field]} ->
        legacy_expr_ast(
          meta,
          legacy_expr(:field, "item", meta, caller),
          {:_item, name, field}
        )

      {:index, meta, [name]} ->
        {:index, meta, [name]}

      {:part_id, meta, [name]} ->
        {:part_id, meta, [name]}

      {:path_for, _meta, [app, screen]} ->
        quote do
          {:_path_for, unquote(Macro.expand(app, caller)), unquote(screen),
           unquote(Macro.escape(%{}))}
        end

      {:path_for, _meta, [app, screen, params]} ->
        quote do
          {:_path_for, unquote(Macro.expand(app, caller)), unquote(screen),
           unquote(Macro.escape(runtime_value_data(params, caller)))}
        end

      {:can, _meta, [action]} ->
        capability_call(action, %{})

      {:can, _meta, [action, bindings]} ->
        capability_call(action, rewrite_helpers(bindings, caller))

      other ->
        other
    end)
  end

  defp capability_call(action, bindings) do
    quote do
      {:__ash_ui_can__, unquote(action), unquote(Macro.escape(bindings))}
    end
  end

  defp runtime_value_data({:%{}, _meta, values}, caller) when is_list(values) do
    Enum.into(values, %{}, fn {key, value} -> {key, runtime_value_data(value, caller)} end)
  end

  defp runtime_value_data({:runtime_call, _meta, [_module, _function, _args]}, caller) do
    raise_runtimecall_removed!(caller)
  end

  defp runtime_value_data({name, _meta, context}, _caller)
       when is_atom(name) and is_atom(context) do
    {:_ref, [], name}
  end

  defp runtime_value_data({name, _meta, [name_arg]}, _caller)
       when name in [
              :arg,
              :context,
              :event,
              :result,
              :index,
              :part_id
            ] and is_atom(name_arg) do
    runtime_accessor_marker(name, name_arg)
  end

  defp runtime_value_data({:screen_variant, _meta, []}, _caller) do
    {:_context, :screen_variant}
  end

  defp runtime_value_data({:item, _meta, [item_name, field]}, _caller)
       when is_atom(item_name) do
    {:_item, item_name, field}
  end

  defp runtime_value_data({:item, _meta, [field]}, _caller) do
    {:_item, :__single__, field}
  end

  defp runtime_value_data({:field, meta, [item_name, field]}, caller) when is_atom(item_name) do
    {:__ash_ui_legacy_expr__, legacy_expr(:field, "item", meta, caller),
     {:_item, item_name, field}}
  end

  defp runtime_value_data({name, _meta, [value, segments]}, caller)
       when name in [:get_path, :path] and is_list(segments) do
    {name, [], [runtime_value_data(value, caller), runtime_value_data(segments, caller)]}
  end

  defp runtime_value_data({name, _meta, []}, _caller) when name in [:errors] do
    runtime_accessor_marker(name)
  end

  defp runtime_value_data({:path_for, _meta, [app, screen]}, caller) do
    {:_path_for, Macro.expand(app, caller), screen, %{}}
  end

  defp runtime_value_data({:path_for, _meta, [app, screen, params]}, caller) do
    {:_path_for, Macro.expand(app, caller), screen, runtime_value_data(params, caller)}
  end

  defp runtime_value_data({{:., dot_meta, [module_ast, function_name]}, call_meta, args}, caller)
       when is_atom(function_name) and is_list(args) do
    expanded_module = Macro.expand(module_ast, caller)

    cond do
      expanded_module == Ash.Expr ->
        {{:., dot_meta, [module_ast, function_name]}, call_meta,
         Enum.map(args, &runtime_value_data(&1, caller))}

      args == [] and accessor_base_ast?(module_ast) ->
        {{:., dot_meta, [runtime_value_data(module_ast, caller), function_name]}, call_meta, []}

      true ->
        raise ArgumentError,
              "unsupported remote expr call #{inspect(expanded_module)}.#{function_name}/#{length(args)} in runtime value data"
    end
  end

  defp runtime_value_data({name, _meta, args}, caller) when is_atom(name) and is_list(args) do
    {:call, name, Enum.map(args, &runtime_value_data(&1, caller))}
  end

  defp runtime_value_data(list, caller) when is_list(list) do
    Enum.map(list, &runtime_value_data(&1, caller))
  end

  defp runtime_value_data(other, _caller), do: other

  defp accessor_base_ast?({:__aliases__, _meta, _parts}), do: false
  defp accessor_base_ast?(module) when is_atom(module), do: false
  defp accessor_base_ast?(_ast), do: true

  defp runtime_accessor_marker(:arg, name), do: {:_arg, name}
  defp runtime_accessor_marker(:context, name), do: {:_context, name}
  defp runtime_accessor_marker(:event, name), do: {:_event, name}
  defp runtime_accessor_marker(:result, name), do: {:_result, name}
  defp runtime_accessor_marker(:index, name), do: {:_index, name}
  defp runtime_accessor_marker(:part_id, name), do: {:_part_id, name}

  defp runtime_accessor_marker(:errors), do: {:_errors}

  defp legacy_expr(form, replacement, meta, caller) do
    %{
      form: form,
      replacement: replacement,
      location: [file: caller.file, line: Keyword.get(meta, :line, caller.line)]
    }
  end

  defp legacy_expr_ast(meta, legacy, expression_ast) do
    {:{}, meta,
     [
       :__ash_ui_legacy_expr__,
       Macro.escape(legacy),
       {:{}, meta, Tuple.to_list(expression_ast)}
     ]}
  end

  defp expand_expr(body, caller) do
    case body do
      {:case, _meta, _args} ->
        compiled = AshUi.ExprCompiler.compile!({:expr, [], [[do: body]]})

        quote do
          unquote(Macro.escape(compiled))
        end

      _other ->
        expand_ash_expr(body, caller)
    end
  end

  @eager_operators [:||, :&&, :and, :or, :<>, :==, :!=, :<, :<=, :>, :>=, :+, :-, :*, :/, :in]

  defp expand_ash_expr(body, caller) do
    rewritten = rewrite_helpers(body, caller)

    if capability_marker?(rewritten) do
      # Bare emission: capability-marker exprs skip the Ash.Expr.expr
      # wrapper, so (a) pinned accessor rewrites would be misplaced pins —
      # de-pin them to canonical marker tuples; (b) Elixir operators around
      # markers would evaluate EAGERLY at view build (marker tuples are
      # truthy, so a || b silently collapses to a) — reject them with
      # guidance instead of persisting broken semantics.
      reject_eager_operator_capability_expr!(rewritten, body, caller)

      quote do
        unquote(depin_capability_accessors(rewritten))
      end
    else
      quote do
        require Ash.Expr
        Ash.Expr.expr(unquote(rewritten))
      end
    end
  end

  defp reject_eager_operator_capability_expr!(rewritten, body, caller) do
    has_operator? =
      {rewritten, false}
      |> then(fn {ast, _} ->
        {_, found} =
          Macro.prewalk(ast, false, fn
            {op, _meta, [_, _]} = node, _acc when op in @eager_operators -> {node, true}
            node, acc -> {node, acc}
          end)

        found
      end)

    if has_operator? do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "expr(...) combining path_for/can " <>
            "capability accessors with operators (||, ==, <>, ...) is not " <>
            "supported: the expression cannot be wrapped in Ash.Expr and the " <>
            "operators would evaluate eagerly at view build, silently dropping " <>
            "operands. Use if(...)/case(...) forms instead. Got: " <>
            Macro.to_string(body)
    end

    :ok
  end

  defp depin_capability_accessors(ast) do
    Macro.postwalk(ast, fn
      {:^, _, [{{:., _, [aliases, fun]}, _, [name]}]} = node ->
        if ash_expr_alias?(aliases) do
          case fun do
            :ref -> {:{}, [], [:_ref, [], name]}
            :arg -> {:_arg, name}
            :context -> {:_context, name}
            _other -> node
          end
        else
          node
        end

      node ->
        node
    end)
  end

  defp ash_expr_alias?({:__aliases__, _, [:Ash, :Expr]}), do: true
  defp ash_expr_alias?(Ash.Expr), do: true
  defp ash_expr_alias?(_other), do: false

  defp capability_marker?({:{}, _, [:__ash_ui_can__, _, _]}), do: true
  defp capability_marker?({:{}, _, [:__ash_ui_legacy_expr__, _, _]}), do: true
  defp capability_marker?({:{}, _, [:_path_for, _, _, _]}), do: true
  defp capability_marker?({:__ash_ui_legacy_expr__, _, _}), do: true
  defp capability_marker?({:__ash_ui_can__, _, _}), do: true
  defp capability_marker?({:_path_for, _, _, _}), do: true

  defp capability_marker?({:%{}, _meta, pairs}) when is_list(pairs) do
    Enum.any?(pairs, fn {key, value} -> capability_marker?(key) or capability_marker?(value) end)
  end

  defp capability_marker?(list) when is_list(list), do: Enum.any?(list, &capability_marker?/1)

  defp capability_marker?(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.any?(&capability_marker?/1)
  end

  defp capability_marker?(_other), do: false

  defp raise_runtimecall_removed!(caller) do
    raise Spark.Error.DslError.exception(
            module: caller.module,
            path: [:ash_ui],
            message:
              "runtime_call/3 is no longer supported in authored expressions; use Ash calculations, Ash.CustomExpression modules, or stdlib calls where possible: coalesce/2..N, default/2, present?/1, blank?/1, empty?/1, humanize/1, truncate/2, join/2, count/1, sort_by/2-3, strip_prefix/2"
          )
  end
end
