defmodule AshUi.ExprCompiler do
  @moduledoc """
  Shared compiler from source expression syntax to Ash-native expressions.
  """

  alias Ash.Query.{Call, Not, Ref}
  alias AshUi.Expr.Compiled
  alias AshUi.Expr.Registry
  alias Spark.Error.DslError

  @binary_ops [:==, :!=, :<, :<=, :>, :>=, :+, :-, :*, :/, :<>, :in]
  @boolean_ops [:and, :or, :||]
  @ops @binary_ops ++ @boolean_ops
  @unary_ops [:not]
  @native_ash_calls %{
    :! => [1],
    :not => [1],
    :if => [2],
    :is_nil => [1],
    :fragment => {:min, 1},
    :string_split => [1, 2, 3],
    :== => [2],
    :!= => [2],
    :< => [2],
    :<= => [2],
    :> => [2],
    :>= => [2],
    :+ => [2],
    :- => [2],
    :* => [2],
    :/ => [2],
    :<> => [2],
    :in => [2],
    :and => [2],
    :or => [2],
    :|| => [2]
  }
  @stdlib_alternatives "coalesce/2..N (compiled to if/is_nil), native Ash if/2, is_nil/1, operators, default/2, present?/1, blank?/1, empty?/1, join/2, count/1, sort_by/2-3, and registered Ash.CustomExpression calls such as humanize/1, truncate/2, relative_time/1, time_ago_in_words/1, strip_prefix/2"

  @doc false
  # Introspection for the closed-world expression gate: every key must be Ash
  # registry-native, a registered Ash.CustomExpression, or parser-level
  # boolean syntax. Never a hand-invented name.
  def native_ash_calls, do: @native_ash_calls

  @spec compile!(term(), keyword()) :: Compiled.t()
  def compile!(expression, opts \\ [])

  def compile!(%Compiled{ir: ir} = compiled, _opts) do
    normalized =
      ir
      |> rewrite_non_native_calls()
      |> normalize_compiled_expression()
      |> normalize_each_bindings()

    %Compiled{compiled | ir: normalized, deps: deps(normalized)}
  end

  def compile!(expression, opts) do
    ir = compile_ir!(expression, opts)

    %Compiled{
      source: inspect(expression),
      ir: ir,
      deps: deps(ir)
    }
  end

  # coalesce/2..N is NOT native Ash (lane 1: Ash.Error.Query.NoSuchFunction
  # in 3.29.3) — rewritten at compile time into exact if/is_nil chains so
  # the IR carries only Ash-native calls and ONE semantics serves SQL
  # pushdown, Ash runtime eval, and the render path.
  defp rewrite_non_native_calls(%Ash.Query.Call{name: :coalesce, args: [only]}),
    do: rewrite_non_native_calls(only)

  defp rewrite_non_native_calls(%Ash.Query.Call{name: :coalesce, args: [first | rest]} = call) do
    first = rewrite_non_native_calls(first)
    rest_expr = rewrite_non_native_calls(%Ash.Query.Call{call | args: rest})

    %Ash.Query.Call{
      name: :if,
      args: [
        %Ash.Query.Call{name: :is_nil, args: [first], operator?: false, relationship_path: []},
        [do: rest_expr, else: first]
      ],
      operator?: false,
      relationship_path: []
    }
  end

  defp rewrite_non_native_calls(%Ash.Query.Call{args: args} = call),
    do: %Ash.Query.Call{call | args: rewrite_non_native_calls(args)}

  defp rewrite_non_native_calls(%Ash.Query.BooleanExpression{left: left, right: right} = expr),
    do: %Ash.Query.BooleanExpression{
      expr
      | left: rewrite_non_native_calls(left),
        right: rewrite_non_native_calls(right)
    }

  defp rewrite_non_native_calls(%Ash.Query.Not{expression: inner} = expr),
    do: %Ash.Query.Not{expr | expression: rewrite_non_native_calls(inner)}

  defp rewrite_non_native_calls({:call, :coalesce, [only]}),
    do: rewrite_non_native_calls(only)

  defp rewrite_non_native_calls({:call, :coalesce, [first | rest]}) do
    rewrite_non_native_calls(%Ash.Query.Call{
      name: :coalesce,
      args: [first | rest],
      operator?: false,
      relationship_path: []
    })
  end

  defp rewrite_non_native_calls(list) when is_list(list),
    do: Enum.map(list, &rewrite_non_native_calls/1)

  defp rewrite_non_native_calls(%module{} = struct) do
    fields =
      struct
      |> Map.from_struct()
      |> Map.new(fn {key, value} -> {key, rewrite_non_native_calls(value)} end)

    struct(module, fields)
  end

  defp rewrite_non_native_calls(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, rewrite_non_native_calls(v)} end)

  defp rewrite_non_native_calls(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&rewrite_non_native_calls/1) |> List.to_tuple()

  defp rewrite_non_native_calls(other), do: other

  @spec finalize_calls!(term(), keyword()) :: term()
  def finalize_calls!(term, opts \\ []) when is_list(opts) do
    term
    |> rewrite_non_native_calls()
    |> do_finalize_calls(opts, List.wrap(Keyword.get(opts, :dsl_path, [])))
  end

  defp compile_ir!(%Compiled{ir: ir}, _opts), do: ir

  defp compile_ir!(expression, opts) do
    compiled =
      if Ash.Expr.expr?(expression) do
        expression
      else
        do_compile(expression, opts)
      end

    compiled
    |> rewrite_non_native_calls()
    |> normalize_compiled_expression()
    |> normalize_each_bindings()
  end

  defp do_compile({:expr, _meta, [[do: body]]}, opts), do: compile_ast(body, opts)
  defp do_compile({:expr, _meta, [body]}, opts), do: compile_ast(body, opts)
  defp do_compile({:value, value}, _opts), do: value

  defp do_compile({:__ash_ui_legacy_expr__, legacy, expression}, opts)
       when is_map(legacy) do
    {:__ash_ui_legacy_expr__, legacy, compile_ir!(expression, opts)}
  end

  defp do_compile({:__ash_ui_singleton__, expression}, opts) do
    {:__ash_ui_singleton__, compile_ir!(expression, opts)}
  end

  defp do_compile({:call, :concat, arguments}, opts) when is_list(arguments) do
    arguments
    |> Enum.map(&compile_ir!(&1, opts))
    |> compile_concat!()
  end

  defp do_compile({:call, :not, [argument]}, opts) do
    %Not{expression: compile_ir!(argument, opts)}
  end

  defp do_compile({:call, name, arguments}, opts) when is_atom(name) and is_list(arguments) do
    %Call{
      name: name,
      args: Enum.map(arguments, &compile_ir!(&1, opts)),
      operator?: false,
      relationship_path: []
    }
  end

  defp do_compile(%{} = expression, _opts), do: expression

  defp do_compile(literal, _opts), do: literal

  defp compile_ast({:%{}, _meta, pairs}, opts) when is_list(pairs) do
    Map.new(pairs, fn {key, value} -> {compile_ast(key, opts), compile_ast(value, opts)} end)
  end

  defp compile_ast({:arg, _meta, [arg]}, _opts) when is_atom(arg) or is_binary(arg),
    do: {:_arg, arg}

  defp compile_ast({:context, _meta, [arg]}, _opts) when is_atom(arg) or is_binary(arg),
    do: {:_context, arg}

  defp compile_ast({name, _meta, [arg]}, _opts)
       when name in [
              :event,
              :index,
              :part_id,
              :result
            ] and (is_atom(arg) or is_binary(arg)) do
    marker = Registry.fetch(name) |> elem(1) |> Map.fetch!(:marker)
    List.to_tuple([marker, arg])
  end

  defp compile_ast({name, _meta, []}, _opts) when name in [:result, :errors] do
    marker = Registry.fetch(name) |> elem(1) |> Map.fetch!(:marker)
    {marker}
  end

  defp compile_ast({:item, _meta, [item_name, field]}, opts) when is_atom(item_name) do
    {:_item, item_name, compile_ast(field, opts)}
  end

  defp compile_ast({:item, _meta, [field]}, opts) do
    {:_item, :__single__, compile_ast(field, opts)}
  end

  defp compile_ast({:__ash_ui_legacy_expr__, legacy, expression}, opts)
       when is_map(legacy) do
    {:__ash_ui_legacy_expr__, legacy, compile_ast(expression, opts)}
  end

  defp compile_ast({:__ash_ui_singleton__, expression}, opts) do
    {:__ash_ui_singleton__, compile_ast(expression, opts)}
  end

  defp compile_ast({:path_for, _meta, [app, screen, params]}, opts) do
    {:_path_for, app, screen, compile_ast(params, opts)}
  end

  defp compile_ast({:can, _meta, [action]}, opts),
    do: compile_ast({:can, [], [action, %{}]}, opts)

  defp compile_ast({:can, _meta, [action, bindings]}, opts) when is_atom(action) do
    {:__ash_ui_can__, action, compile_ast(bindings, opts)}
  end

  defp compile_ast({:if, _meta, [condition, branches]}, opts) when is_list(branches) do
    %Call{
      name: :if,
      args: [compile_ast(condition, opts), compile_ast(branches, opts)],
      operator?: false,
      relationship_path: []
    }
  end

  defp compile_ast({:case, _meta, [value, [do: clauses]]}, opts) when is_list(clauses) do
    %Call{
      name: :case,
      args: [compile_ast(value, opts), Enum.map(clauses, &compile_case_clause!(&1, opts))],
      operator?: false,
      relationship_path: []
    }
  end

  defp compile_ast({op, _meta, [left, right]}, opts) when op in @ops do
    %Call{
      name: op,
      args: [compile_ast(left, opts), compile_ast(right, opts)],
      operator?: true,
      relationship_path: []
    }
  end

  defp compile_ast({op, _meta, [value]}, opts) when op in @unary_ops do
    %Call{name: op, args: [compile_ast(value, opts)], operator?: true, relationship_path: []}
  end

  defp compile_ast({:__aliases__, _meta, parts}, _opts) when is_list(parts),
    do: Module.concat(parts)

  defp compile_ast({{:., _dot_meta, [base, field]}, _meta, []}, opts) when is_atom(field) do
    case compile_ast(base, opts) do
      {:_ref, path, name} when is_list(path) ->
        {:_ref, path ++ [name], field}

      {:_item, binding, path} when is_list(path) ->
        {:_item, binding, path ++ [field]}

      other ->
        %Call{name: :get_path, args: [other, [field]], operator?: false, relationship_path: []}
    end
  end

  defp compile_ast({name, _meta, context}, _opts)
       when is_atom(name) and is_atom(context) do
    {:_ref, [], name}
  end

  defp compile_ast({name, _meta, args}, opts) when is_atom(name) and is_list(args) do
    %Call{
      name: name,
      args: Enum.map(args, &compile_ast(&1, opts)),
      operator?: false,
      relationship_path: []
    }
  end

  defp compile_ast({key, value}, opts) when is_atom(key) or is_binary(key) do
    {key, compile_ast(value, opts)}
  end

  defp compile_ast(list, opts) when is_list(list), do: Enum.map(list, &compile_ast(&1, opts))
  defp compile_ast(other, _opts), do: other

  defp compile_case_clause!({:->, _meta, [[pattern], body]}, opts) do
    {compile_case_pattern(pattern, opts), compile_ast(body, opts)}
  end

  defp compile_case_clause!(other, _opts) do
    raise ArgumentError,
          "case expression expects `pattern -> body` clauses, got: #{inspect(other)}"
  end

  defp compile_case_pattern({:_, _meta, _context}, _opts), do: :_
  defp compile_case_pattern(pattern, opts), do: compile_ast(pattern, opts)

  defp compile_concat!([]), do: ""
  defp compile_concat!([single]), do: single

  defp compile_concat!([left, right | rest]) do
    expr = %Call{name: :<>, args: [left, right], operator?: true, relationship_path: []}

    case rest do
      [] -> expr
      _ -> compile_concat!([expr | rest])
    end
  end

  defp normalize_compiled_expression(%Ref{attribute: attribute, relationship_path: path}) do
    {:_ref, List.wrap(path), attribute}
  end

  defp normalize_compiled_expression(%Call{
         name: :arg,
         args: [name],
         operator?: false,
         relationship_path: []
       })
       when is_atom(name) do
    {:_arg, name}
  end

  defp normalize_compiled_expression(
         {:^, _meta,
          [
            {{:., _, [{:__aliases__, _, [:Ash, :Expr]}, :arg]}, _, [name]}
          ]}
       )
       when is_atom(name) do
    {:_arg, name}
  end

  defp normalize_compiled_expression(
         {:^, _meta,
          [
            {{:., _, [{:__aliases__, _, [:Ash, :Expr]}, :context]}, _, [name]}
          ]}
       )
       when is_atom(name) do
    {:_context, name}
  end

  defp normalize_compiled_expression(
         {:^, _meta,
          [
            {{:., _, [{:__aliases__, _, [:Ash, :Expr]}, :ref]}, _, [name]}
          ]}
       )
       when is_atom(name) do
    {:_ref, [], name}
  end

  # Author-written (unpinned) Ash.Expr.* remote calls inside expr(...) survive
  # Ash's expr builder as raw quoted AST. Normalize the accessor trio to
  # markers and apply the remaining constructors at compile time so no quoted
  # alias/hygiene metadata is ever persisted.
  defp normalize_compiled_expression(
         {{:., _, [{:__aliases__, _, [:Ash, :Expr]}, :arg]}, _, [name]}
       )
       when is_atom(name),
       do: {:_arg, name}

  defp normalize_compiled_expression(
         {{:., _, [{:__aliases__, _, [:Ash, :Expr]}, :context]}, _, [name]}
       )
       when is_atom(name),
       do: {:_context, name}

  defp normalize_compiled_expression(
         {{:., _, [{:__aliases__, _, [:Ash, :Expr]}, :ref]}, _, [name]}
       )
       when is_atom(name),
       do: {:_ref, [], name}

  # The expr(...) authoring macro rewrites to a quoted block of
  # `require Ash.Expr; Ash.Expr.expr(body)`; capture paths that defer
  # evaluation (command followups) hand that wrapper to the compiler whole —
  # drop the directives, unwrap, and compile the body normally.
  defp normalize_compiled_expression({:__block__, _meta, statements})
       when is_list(statements) do
    statements
    |> Enum.reject(fn
      {directive, _m, _a} when directive in [:require, :alias, :import] -> true
      _other -> false
    end)
    |> List.last()
    |> normalize_compiled_expression()
  end

  defp normalize_compiled_expression(
         {{:., _, [{:__aliases__, _, [:Ash, :Expr]}, :expr]}, _, [body]}
       ) do
    body
    |> compile_ast([])
    |> normalize_compiled_expression()
  end

  defp normalize_compiled_expression(
         {{:., _, [{:__aliases__, _, [:Ash, :Expr]}, fun]}, _, args} = quoted
       )
       when is_atom(fun) and is_list(args) do
    normalized_args = Enum.map(args, &normalize_compiled_expression/1)

    if Enum.all?(normalized_args, &plain_compile_time_value?/1) and
         function_exported?(Ash.Expr, fun, length(normalized_args)) do
      Ash.Expr
      |> apply(fun, normalized_args)
      |> normalize_compiled_expression()
    else
      raise ArgumentError,
            "Ash.Expr.#{fun}/#{length(args)} inside expr(...) must receive " <>
              "compile-time literal arguments; use the AshUi accessor " <>
              "forms for dynamic values. Got: #{Macro.to_string(quoted)}"
    end
  end

  defp normalize_compiled_expression(%Call{
         name: :context,
         args: [name],
         operator?: false,
         relationship_path: []
       })
       when is_atom(name) do
    {:_context, name}
  end

  defp normalize_compiled_expression(%Call{
         name: :event,
         args: [name],
         operator?: false,
         relationship_path: []
       })
       when is_atom(name) do
    %Call{name: :event, args: [name], operator?: false, relationship_path: []}
  end

  defp normalize_compiled_expression(%Call{
         name: :index,
         args: [name],
         operator?: false,
         relationship_path: []
       })
       when is_atom(name) do
    {:_index, name}
  end

  defp normalize_compiled_expression(%Call{
         name: :part_id,
         args: [name],
         operator?: false,
         relationship_path: []
       })
       when is_atom(name) do
    {:_part_id, name}
  end

  defp normalize_compiled_expression(%Call{
         name: :item,
         args: [item_name, field],
         operator?: false,
         relationship_path: []
       })
       when is_atom(item_name) do
    {:_item, item_name, field}
  end

  defp normalize_compiled_expression(%Call{
         name: :item,
         args: [field],
         operator?: false,
         relationship_path: []
       }) do
    {:_item, :__single__, field}
  end

  defp normalize_compiled_expression({:_path_for, app, screen, params})
       when is_atom(app) and is_atom(screen) do
    {:_path_for, app, screen, normalize_compiled_expression(params)}
  end

  defp normalize_compiled_expression({:__ash_ui_legacy_expr__, legacy, expression})
       when is_map(legacy) do
    {:__ash_ui_legacy_expr__, legacy, normalize_compiled_expression(expression)}
  end

  defp normalize_compiled_expression({:__ash_ui_singleton__, expression}) do
    {:__ash_ui_singleton__, normalize_compiled_expression(expression)}
  end

  defp normalize_compiled_expression({:_arg, name}) when is_atom(name), do: {:_arg, name}

  defp normalize_compiled_expression(%Call{
         name: :result,
         args: [],
         operator?: false,
         relationship_path: []
       }) do
    {:_result}
  end

  defp normalize_compiled_expression(%Call{
         name: :result,
         args: [name],
         operator?: false,
         relationship_path: []
       })
       when is_atom(name) do
    {:_result, name}
  end

  defp normalize_compiled_expression(%Call{
         name: :errors,
         args: [],
         operator?: false,
         relationship_path: []
       }) do
    {:_errors}
  end

  defp normalize_compiled_expression(%Not{expression: expression}) do
    %Not{expression: normalize_compiled_expression(expression)}
  end

  defp normalize_compiled_expression(%Call{} = call) do
    %{call | args: Enum.map(call.args, &normalize_compiled_expression/1)}
  end

  defp normalize_compiled_expression(%module{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.into(%{}, fn {key, value} -> {key, normalize_compiled_expression(value)} end)
    |> then(&struct(module, &1))
  end

  defp normalize_compiled_expression(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} -> {key, normalize_compiled_expression(value)} end)
  end

  defp normalize_compiled_expression(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&normalize_compiled_expression/1)
    |> List.to_tuple()
  end

  defp normalize_compiled_expression(list) when is_list(list) do
    Enum.map(list, &normalize_compiled_expression/1)
  end

  defp normalize_compiled_expression(other), do: other

  @doc false
  def normalize_each_bindings(ir), do: do_normalize_each_bindings(ir, MapSet.new())

  defp do_normalize_each_bindings(
         %Call{name: :each, args: [items, as, opts, body]} = call,
         bindings
       )
       when is_atom(as) do
    body_bindings = MapSet.put(bindings, as)

    %{
      call
      | args: [
          do_normalize_each_bindings(items, bindings),
          as,
          do_normalize_each_bindings(opts, body_bindings),
          do_normalize_each_bindings(body, body_bindings)
        ]
    }
  end

  defp do_normalize_each_bindings({:_ref, [], name}, bindings) when is_atom(name) do
    if MapSet.member?(bindings, name), do: {:_item, name, []}, else: {:_ref, [], name}
  end

  defp do_normalize_each_bindings({:_ref, [binding | path], name}, bindings)
       when is_atom(binding) and is_list(path) do
    if MapSet.member?(bindings, binding) do
      {:_item, binding, path ++ [name]}
    else
      {:_ref, [binding | path], name}
    end
  end

  defp do_normalize_each_bindings(%Ref{relationship_path: [], attribute: name} = ref, bindings)
       when is_atom(name) do
    if MapSet.member?(bindings, name), do: {:_item, name, []}, else: ref
  end

  defp do_normalize_each_bindings(
         %Ref{relationship_path: [binding | path], attribute: name} = ref,
         bindings
       )
       when is_atom(binding) and is_list(path) do
    if MapSet.member?(bindings, binding), do: {:_item, binding, path ++ [name]}, else: ref
  end

  defp do_normalize_each_bindings(%Call{} = call, bindings) do
    %{call | args: Enum.map(call.args, &do_normalize_each_bindings(&1, bindings))}
  end

  defp do_normalize_each_bindings(%Not{expression: expression} = not_expr, bindings) do
    %{not_expr | expression: do_normalize_each_bindings(expression, bindings)}
  end

  defp do_normalize_each_bindings(%Ash.Query.BooleanExpression{} = expr, bindings) do
    %{
      expr
      | left: do_normalize_each_bindings(expr.left, bindings),
        right: do_normalize_each_bindings(expr.right, bindings)
    }
  end

  defp do_normalize_each_bindings(%Ash.Query.Exists{} = exists, bindings) do
    %{exists | expr: do_normalize_each_bindings(exists.expr, bindings)}
  end

  defp do_normalize_each_bindings(%Compiled{} = compiled, bindings) do
    %Compiled{compiled | ir: do_normalize_each_bindings(compiled.ir, bindings)}
  end

  defp do_normalize_each_bindings(%module{} = struct, bindings) do
    struct
    |> Map.from_struct()
    |> Enum.into(%{}, fn {key, value} ->
      {key, do_normalize_each_bindings(value, bindings)}
    end)
    |> then(&struct(module, &1))
  end

  defp do_normalize_each_bindings(map, bindings) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      {do_normalize_each_bindings(key, bindings), do_normalize_each_bindings(value, bindings)}
    end)
  end

  defp do_normalize_each_bindings(list, bindings) when is_list(list),
    do: Enum.map(list, &do_normalize_each_bindings(&1, bindings))

  defp do_normalize_each_bindings(tuple, bindings) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&do_normalize_each_bindings(&1, bindings))
    |> List.to_tuple()
  end

  defp do_normalize_each_bindings(other, _bindings), do: other

  def deps(%Compiled{ir: ir}), do: deps(ir)
  def deps(ir), do: ir |> collect_deps([]) |> Enum.reverse() |> Enum.uniq()

  defp collect_deps(%Compiled{ir: ir}, acc), do: collect_deps(ir, acc)

  # Path-faithful, matching Ash.Filter.list_refs output (lane 3: the old
  # clause dropped relationship_path, masked only by normalization order).
  # Hydrated refs carry attribute STRUCTS; raw ones carry atoms.
  defp collect_deps(%Ref{attribute: attribute, relationship_path: path}, acc) do
    name =
      case attribute do
        %{name: name} -> name
        name when is_atom(name) -> name
      end

    [{:state, List.wrap(path) ++ [name]} | acc]
  end

  defp collect_deps({:_ref, path, attribute}, acc) when is_list(path) do
    [{:state, path ++ [attribute]} | acc]
  end

  defp collect_deps({:_context, key}, acc), do: [{:context, [key]} | acc]
  defp collect_deps({:_arg, key}, acc), do: [{:arg, [key]} | acc]

  # field_errors/1 reads scope errors implicitly — the dep must say so or
  # error-state changes never invalidate the slot.
  defp collect_deps(%Call{name: :field_errors, args: args}, acc) do
    Enum.reduce(args, [{:errors, []} | acc], &collect_deps/2)
  end

  defp collect_deps(%Call{args: args}, acc), do: Enum.reduce(args, acc, &collect_deps/2)

  defp collect_deps(%Ash.Query.BooleanExpression{left: left, right: right}, acc) do
    right
    |> collect_deps(collect_deps(left, acc))
  end

  # refs inside exists(path, ...) are RELATIVE to the path — prefix them
  defp collect_deps(%Ash.Query.Exists{path: path, expr: expr}, acc) do
    expr
    |> collect_deps([])
    |> Enum.map(fn
      {:state, inner} when is_list(inner) -> {:state, List.wrap(path) ++ inner}
      {:state, inner} when is_atom(inner) -> {:state, List.wrap(path) ++ [inner]}
      other -> other
    end)
    |> Kernel.++(acc)
  end

  defp collect_deps(%Not{expression: expression}, acc), do: collect_deps(expression, acc)

  defp collect_deps(tuple, acc) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    marker = elem(tuple, 0)
    arity = tuple_size(tuple) - 1

    acc =
      case Registry.accessor_name(marker, arity) do
        nil -> acc
        name -> [{name, Tuple.to_list(tuple) |> tl()} | acc]
      end

    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, &collect_deps/2)
  end

  defp collect_deps(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_deps/2)

  defp collect_deps(%_{} = struct, acc) do
    struct
    |> Map.from_struct()
    |> collect_deps(acc)
  end

  defp collect_deps(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {key, value}, deps ->
      collect_deps(value, collect_deps(key, deps))
    end)
  end

  defp collect_deps(_other, acc), do: acc

  defp do_finalize_calls(%Compiled{} = compiled, opts, path) do
    ir = do_finalize_calls(compiled.ir, opts, path ++ [:ir])
    %Compiled{compiled | ir: ir, deps: deps(ir)}
  end

  defp do_finalize_calls(%Call{name: :^, args: [inner]}, opts, path) do
    inner
    |> normalize_compiled_expression()
    |> do_finalize_calls(opts, path)
  end

  defp do_finalize_calls(%Call{} = call, opts, path) do
    args =
      call.args
      |> Enum.with_index()
      |> Enum.map(fn {arg, index} -> do_finalize_calls(arg, opts, path ++ [:args, index]) end)

    %{call | args: args}
    |> resolve_call!(opts, path)
  end

  defp do_finalize_calls(%Not{expression: expression} = not_expr, opts, path) do
    %Not{not_expr | expression: do_finalize_calls(expression, opts, path ++ [:expression])}
  end

  defp do_finalize_calls(%Ash.Query.BooleanExpression{} = expr, opts, path) do
    %{
      expr
      | left: do_finalize_calls(expr.left, opts, path ++ [:left]),
        right: do_finalize_calls(expr.right, opts, path ++ [:right])
    }
  end

  defp do_finalize_calls(%Ash.Query.Exists{} = exists, opts, path) do
    %{exists | expr: do_finalize_calls(exists.expr, opts, path ++ [:expr])}
  end

  defp do_finalize_calls({:^, _meta, [inner]}, opts, path) do
    inner
    |> normalize_compiled_expression()
    |> do_finalize_calls(opts, path)
  end

  defp do_finalize_calls({:call, name, args}, opts, path)
       when is_atom(name) and is_list(args) do
    args =
      args
      |> Enum.with_index()
      |> Enum.map(fn {arg, index} -> do_finalize_calls(arg, opts, path ++ [:args, index]) end)

    %Call{name: name, args: args, operator?: name in @ops, relationship_path: []}
    |> resolve_call!(opts, path)
  end

  defp do_finalize_calls({:__ash_ui_legacy_expr__, legacy, expression}, opts, path)
       when is_map(legacy) do
    {:__ash_ui_legacy_expr__, legacy,
     do_finalize_calls(expression, opts, path ++ [:expression])}
  end

  defp do_finalize_calls({:__ash_ui_singleton__, expression}, opts, path) do
    {:__ash_ui_singleton__, do_finalize_calls(expression, opts, path ++ [:expression])}
  end

  defp do_finalize_calls(%module{} = struct, opts, path) do
    struct
    |> Map.from_struct()
    |> Enum.into(%{}, fn {key, value} ->
      {key, do_finalize_calls(value, opts, path ++ [key])}
    end)
    |> then(&struct(module, &1))
  end

  defp do_finalize_calls(map, opts, path) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      {do_finalize_calls(key, opts, path ++ [:key]),
       do_finalize_calls(value, opts, path ++ [key])}
    end)
  end

  defp do_finalize_calls(list, opts, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> do_finalize_calls(value, opts, path ++ [index]) end)
  end

  defp do_finalize_calls(tuple, opts, path) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.map(fn {value, index} -> do_finalize_calls(value, opts, path ++ [index]) end)
    |> List.to_tuple()
  end

  defp do_finalize_calls(other, _opts, _path), do: other

  defp resolve_call!(%Call{name: name, args: args} = call, opts, path) do
    arity = length(args)

    cond do
      Registry.stdlib_name?(name) ->
        validate_stdlib_arity!(name, arity, opts, path)
        call

      native_ash_call?(name, arity) ->
        call

      custom_expression_call?(name, arity) ->
        call

      name in [:arg, :context] and arity == 1 ->
        call

      Registry.constructor_name?(name) ->
        call

      Registry.accessor_name?(name) ->
        call

      Keyword.get(opts, :strict_calls?, false) ->
        raise_unknown_call!(name, arity, opts, path)

      true ->
        call
    end
  end

  defp validate_stdlib_arity!(name, arity, opts, path) do
    unless Registry.valid_stdlib_arity?(name, arity) do
      {:ok, call} = Registry.fetch_stdlib(name)

      raise_dsl!(
        "expression stdlib helper #{name}/#{arity} has invalid arity; expected #{format_arities(call)}",
        opts,
        path
      )
    end
  end

  defp native_ash_call?(name, arity) when is_atom(name) and is_integer(arity) do
    case Map.fetch(@native_ash_calls, name) do
      {:ok, {:min, min_arity}} -> arity >= min_arity
      {:ok, arities} -> arity in arities
      :error -> match?({:ok, _module}, Registry.fetch_native_ash_function(name, arity))
    end
  end

  defp native_ash_call?(_name, _arity), do: false

  defp custom_expression_call?(name, arity) when is_atom(name) and is_integer(arity) do
    name
    |> custom_expression_modules_for_name()
    |> Enum.any?(fn module ->
      custom_expression_arity?(module, arity)
    end)
  end

  defp custom_expression_call?(_name, _arity), do: false

  defp custom_expression_modules_for_name(name) when is_atom(name) do
    :ash
    |> Application.get_env(:custom_expressions, [])
    |> List.wrap()
    |> Enum.filter(fn module ->
      match?({:module, _}, Code.ensure_compiled(module)) and function_exported?(module, :name, 0) and
        module.name() == name
    end)
  end

  defp custom_expression_arity?(module, arity) do
    function_exported?(module, :arguments, 0) and
      Enum.any?(module.arguments(), &(length(List.wrap(&1)) == arity))
  rescue
    _error in [ArgumentError, UndefinedFunctionError] -> false
  end

  defp raise_unknown_call!(name, arity, opts, path) do
    raise_dsl!(
      "unknown expression call #{name}/#{arity}; use native Ash expressions, AshUi constructors/accessors, stdlib calls, or registered Ash.CustomExpression modules. Supported examples: #{@stdlib_alternatives}",
      opts,
      path
    )
  end

  defp raise_dsl!(message, opts, path) do
    dsl_module = Keyword.get(opts, :dsl_module)

    if is_atom(dsl_module) do
      raise DslError.exception(
              module: dsl_module,
              path: List.wrap(path),
              message: message
            )
    else
      raise DslError.exception(message: message)
    end
  end

  defp format_arities(%{arities: arities}), do: Enum.map_join(arities, ", ", &Integer.to_string/1)

  defp plain_compile_time_value?(value)
       when is_atom(value) or is_binary(value) or is_number(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp plain_compile_time_value?(value) when is_list(value),
    do: Enum.all?(value, &plain_compile_time_value?/1)

  defp plain_compile_time_value?(%_{}), do: false

  defp plain_compile_time_value?(value) when is_map(value),
    do:
      Enum.all?(value, fn {k, v} ->
        plain_compile_time_value?(k) and plain_compile_time_value?(v)
      end)

  defp plain_compile_time_value?(value) when is_tuple(value), do: false
  defp plain_compile_time_value?(_value), do: false
end
