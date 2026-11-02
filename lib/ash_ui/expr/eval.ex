defmodule AshUi.Expr.Eval do
  @moduledoc false

  alias Ash.Query.Call
  alias AshUi.Expr.{Compiled, Registry, Scope}
  alias AshUi.Expressions

  @scope_markers [
    :_ref,
    :_item,
    :_index,
    :_arg,
    :_result,
    :_errors,
    :_actor,
    :_context,
    :_event,
    :_part_id,
    :_path_for,
    :__ash_ui_can__
  ]
  @operators Enum.map(Ash.Filter.builtin_operators(), & &1.operator())

  @spec eval(term(), Scope.t()) :: {:ok, term()} | {:error, term()}
  def eval(expression, %Scope{} = scope) do
    {:ok, eval!(expression, scope)}
  rescue
    # broad rescue: public expression evaluation returns arbitrary runtime failures as tagged errors.
    error -> {:error, error}
  end

  # The only evaluation engine is Ash. This pass binds AshUi's view scope
  # and lowers syntax; it never executes an operator or chooses an If branch.
  def eval!(expression, %Scope{} = scope) do
    expression |> resolve(scope) |> Expressions.evaluate!()
  end

  @doc false
  def resolve(%Compiled{ir: ir}, scope), do: resolve(ir, scope)

  def resolve(%Ash.Query.Ref{attribute: attribute, relationship_path: path}, scope),
    do: Expressions.literal(lookup_ref(scope, List.wrap(path), attribute))

  def resolve(%Ash.Query.Not{expression: inner} = node, scope),
    do: %{node | expression: resolve(inner, scope)}

  def resolve(%Ash.Query.BooleanExpression{op: :||, left: left, right: right}, scope),
    do: resolve(%Call{name: :default, args: [left, right]}, scope)

  def resolve(%Ash.Query.BooleanExpression{left: left, right: right} = node, scope),
    do: %{node | left: resolve(left, scope), right: resolve(right, scope)}

  def resolve(%Call{name: name, args: [left, right]}, scope) when name in [:and, :or],
    do: %Ash.Query.BooleanExpression{
      op: name,
      left: resolve(left, scope),
      right: resolve(right, scope)
    }

  def resolve(%Call{name: name, args: [inner]}, scope) when name in [:not, :!],
    do: %Ash.Query.Not{expression: resolve(inner, scope)}

  def resolve(%Call{name: :||, args: args}, scope),
    do: resolve(%Call{name: :default, args: args}, scope)

  def resolve(%Call{name: :if, args: [condition, branches]}, scope) when is_list(branches) do
    resolve(%Ash.Query.Function.If{arguments: [condition, branches[:do], branches[:else]]}, scope)
  end

  def resolve(%Call{name: :if, args: [condition, yes, no]}, scope),
    do: resolve(%Ash.Query.Function.If{arguments: [condition, yes, no]}, scope)

  def resolve(%Ash.Query.Function.If{arguments: [condition, yes, no]} = node, scope) do
    %{
      node
      | arguments: [
          resolve(condition, scope),
          Expressions.defer(resolve(yes, scope)),
          Expressions.defer(resolve(no, scope))
        ]
    }
  end

  # Bind the candidate once. Default's empty-value rule belongs exclusively
  # to its registered CustomExpression; Ash If owns fallback selection.
  def resolve(%Call{name: :default, args: [value, fallback]}, scope) do
    value = resolve(value, scope)
    fallback = Expressions.defer(resolve(fallback, scope))

    %Ash.Query.Function.Fragment{
      arguments: [
        fn [value] ->
          Expressions.evaluate!(%Call{
            name: :default,
            args: [Expressions.literal(value), fallback]
          })
        end,
        [value]
      ]
    }
  end

  # Ash rejects case syntax. Bind its subject once, then lower ordered exact
  # patterns/wildcard to native If/Fragment. There is no local branch runner.
  def resolve(%Call{name: :case, args: [value, clauses]}, scope) when is_list(clauses) do
    value = resolve(value, scope)

    clauses =
      Enum.map(clauses, fn {pattern, body} ->
        pattern =
          case pattern do
            {:_, _, _} -> :_
            pattern -> resolve(pattern, scope)
          end

        {pattern, resolve(body, scope)}
      end)

    %Ash.Query.Function.Fragment{
      arguments: [
        fn [value] ->
          clauses
          |> Enum.reverse()
          |> Enum.reduce(nil, fn {pattern, body}, rest ->
            predicate =
              case pattern do
                :_ ->
                  true

                {:_, _, _} ->
                  true

                pattern ->
                  %Ash.Query.Function.Fragment{
                    arguments: [
                      fn [pattern, subject] -> pattern == subject end,
                      [pattern, Expressions.literal(value)]
                    ]
                  }
              end

            %Ash.Query.Function.If{
              arguments: [predicate, Expressions.defer(body), Expressions.defer(rest)]
            }
          end)
          |> Expressions.evaluate!()
        end,
        [value]
      ]
    }
  end

  def resolve(%Call{name: :field_errors, args: [field]} = node, scope),
    do: %{node | args: [Expressions.literal(scope.errors), resolve(field, scope)]}

  def resolve(%Call{name: name, args: [key]}, scope)
      when name in [:arg, :actor, :context, :index, :part_id, :result, :event] do
    resolve(List.to_tuple([String.to_existing_atom("_#{name}"), key]), scope)
  end

  def resolve(%Call{name: name, args: []}, scope) when name in [:errors, :result],
    do: resolve({String.to_existing_atom("_#{name}")}, scope)

  def resolve(%Call{name: :item, args: [name, field]}, scope),
    do: resolve({:_item, name, field}, scope)

  def resolve(%Call{name: :item, args: [field]}, scope),
    do: resolve({:_item, :__single__, field}, scope)

  def resolve(%Call{name: :path_for, args: [app, screen, params]}, scope),
    do: resolve({:_path_for, app, screen, params}, scope)

  def resolve(%Call{name: :path} = node, scope), do: resolve(%{node | name: :get_path}, scope)

  def resolve(%Call{name: :fragment, args: [callback | args]} = node, scope),
    do: %{node | args: [callback | Enum.map(args, &resolve(&1, scope))]}

  def resolve(%Call{args: args} = node, scope) do
    # Expand registered syntax before binding it: custom expressions may emit
    # native If nodes (conditional classes, for example). Ash's public registry
    # also disambiguates value count from its inline-aggregate Call syntax.
    case Ash.Filter.custom_expression(node.name, args) do
      {module, arguments} ->
        {:ok, expression} =
          Ash.CustomExpression.expression(module, Ash.DataLayer.Simple, arguments)

        resolve(expression, scope)

      _not_custom ->
        %{
          node
          | args: Enum.map(args, &resolve(&1, scope)),
            operator?: node.operator? or (node.name in @operators and length(args) == 2)
        }
    end
  end

  def resolve(%{__predicate__?: _, name: :||, left: left, right: right}, scope),
    do: resolve(%Call{name: :default, args: [left, right]}, scope)

  def resolve(%{__predicate__?: _, left: left, right: right} = node, scope),
    do: %{node | left: resolve(left, scope), right: resolve(right, scope)}

  def resolve(%{__predicate__?: _, arguments: args} = node, scope),
    do: %{node | arguments: Enum.map(args, &resolve(&1, scope))}

  def resolve(%Ash.CustomExpression{} = node, scope) do
    %{
      node
      | arguments: resolve(node.arguments, scope),
        expression: resolve(node.expression, scope),
        simple_expression:
          case node.simple_expression do
            {:ok, expression} -> {:ok, resolve(expression, scope)}
            other -> other
          end
    }
  end

  def resolve({:__ash_ui_legacy_expr__, _legacy, expression}, scope),
    do: resolve(expression, scope)

  def resolve({:__ash_ui_singleton__, value}, scope) do
    value = resolve(value, scope)

    %Ash.Query.Function.Fragment{
      arguments: [fn [value] -> {:__ash_ui_singleton_value__, value} end, [value]]
    }
  end

  def resolve({:call, name, args}, scope), do: resolve(%Call{name: name, args: args}, scope)

  def resolve(tuple, scope)
      when is_tuple(tuple) and tuple_size(tuple) > 0 and elem(tuple, 0) in @scope_markers,
      do: Expressions.literal(resolve_marker(tuple, scope))

  def resolve(values, scope) when is_list(values), do: Enum.map(values, &resolve(&1, scope))

  def resolve(map, scope) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, resolve(value, scope)} end)

  def resolve(tuple, scope) when is_tuple(tuple) do
    values = tuple |> Tuple.to_list() |> Enum.map(&resolve(&1, scope))
    %Ash.Query.Function.Fragment{arguments: [&List.to_tuple/1, values]}
  end

  def resolve(value, _scope), do: value

  def expression?(%Compiled{}), do: true

  def expression?(value),
    do: Ash.Expr.expr?(value) or Registry.marker_tuple?(value) or ast_call?(value)

  defp resolve_marker({:_result}, %Scope{} = scope), do: scope.result

  defp resolve_marker({:_result, key}, %Scope{} = scope),
    do: lookup_value(scope.result || %{}, key)

  defp resolve_marker({:_errors}, %Scope{} = scope), do: scope.all_errors || scope.errors

  defp resolve_marker({:_actor, key}, %Scope{} = scope) when is_atom(key) or is_binary(key) do
    template_value(:_actor, scope.actor || Map.get(scope.context, :current_user), key)
  end

  defp resolve_marker({:_actor, path}, %Scope{} = scope) when is_list(path) do
    Ash.Expr.fill_template(Ash.Expr.actor(path),
      actor: scope.actor || Map.get(scope.context, :current_user)
    )
  end

  defp resolve_marker({:_context, :__blueprint_runtime__}, %Scope{} = scope),
    do: scope.runtime || lookup_value(scope.context, :__blueprint_runtime__)

  defp resolve_marker({:_context, :__blueprint_path__}, %Scope{} = scope),
    do: scope.path || lookup_value(scope.context, :__blueprint_path__)

  defp resolve_marker({:_context, :__blueprint_props__}, %Scope{} = scope),
    do: scope.props || lookup_value(scope.context, :__blueprint_props__)

  defp resolve_marker({:_context, key}, %Scope{} = scope) when is_atom(key) or is_binary(key) do
    template_value(:_context, scope.context, key)
  end

  defp resolve_marker({:_ref, path, key}, %Scope{} = scope)
       when is_list(path) and (is_atom(key) or is_binary(key)) do
    lookup_ref(scope, path, key)
  end

  defp resolve_marker({:_arg, key}, %Scope{} = scope) when is_atom(key) or is_binary(key) do
    template_value(:_arg, scope.args, key)
  end

  defp resolve_marker({:_event, key}, %Scope{}) when is_atom(key) or is_binary(key),
    do: {:event, key}

  defp resolve_marker({:_index, key}, %Scope{} = scope) when is_atom(key) or is_binary(key) do
    lookup_value(scope.index_bindings, key)
  end

  defp resolve_marker({:_part_id, key}, %Scope{} = scope) when is_atom(key) or is_binary(key) do
    lookup_value(scope.part_ids, key)
  end

  defp resolve_marker({:_item, item_name, field}, %Scope{} = scope) when is_atom(item_name) do
    item =
      cond do
        item_name == :__single__ ->
          single_item_binding(scope.item_bindings)

        is_nil(lookup_value(scope.args, item_name)) ->
          lookup_value(scope.item_bindings, item_name)

        true ->
          lookup_value(scope.args, item_name)
      end

    case {item, field} do
      {nil, _field} -> nil
      {value, empty} when empty in [nil, []] -> value
      {value, field} -> item_field_value(value, field)
    end
  end

  defp resolve_marker({:_path_for, app, screen, _nested_params}, %Scope{} = _scope)
       when is_atom(app) and is_atom(screen) do
    raise ArgumentError,
          "path_for/3 is not supported; declare a route on the target resource"
  end

  defp resolve_marker({:__ash_ui_can__, action, bindings}, %Scope{} = scope)
       when is_atom(action) do
    evaluate_capability(
      action,
      resolve_runtime_param_values(bindings, scope),
      scope.record,
      scope
    )
  end

  defp template_value(marker, values, key) do
    values = values || %{}

    if Map.has_key?(values, key) do
      Ash.Expr.fill_template({marker, key}, actor: values, args: values, context: values)
    else
      # AshUi accepts atom/string aliases at its scope boundary. Ash's
      # actor/context templates require the exact key; bind the alias literally.
      lookup_value(values, key)
    end
  end

  defp single_item_binding(bindings) when map_size(bindings) == 1,
    do: bindings |> Map.values() |> hd()

  defp single_item_binding(_bindings), do: nil

  defp item_field_value(item, field) when is_atom(field) or is_binary(field),
    do: lookup_value(item, field)

  defp item_field_value(item, field), do: lookup_path(item, List.wrap(field))

  def lookup_value(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      is_binary(key) ->
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> nil
          end

        if atom_key && Map.has_key?(map, atom_key), do: Map.get(map, atom_key), else: nil

      true ->
        nil
    end
  end

  def lookup_value(_other, _key), do: nil

  def lookup_path(nil, _segments), do: nil

  def lookup_path(value, segments) do
    Enum.reduce(segments, value, fn segment, acc ->
      cond do
        is_nil(acc) -> nil
        is_map(acc) -> lookup_value(acc, segment)
        is_list(acc) and is_integer(segment) -> Enum.at(acc, segment)
        true -> nil
      end
    end)
  end

  defp lookup_ref(%Scope{} = scope, [], key) do
    scope.state
    |> lookup_path([key])
    |> resolve_missing_ref(scope, key)
  end

  defp lookup_ref(%Scope{} = scope, [base | rest], key) when is_atom(base) or is_binary(base) do
    base_value =
      scope.state
      |> lookup_path([base])
      |> resolve_missing_ref(scope, base)

    lookup_path(base_value, rest ++ [key])
  end

  defp lookup_ref(%Scope{} = scope, path, key), do: lookup_path(scope.state, path ++ [key])

  defp resolve_missing_ref(%Ash.NotLoaded{} = not_loaded, %Scope{} = scope, key),
    do: resolve_not_loaded_ref(not_loaded, scope, key)

  defp resolve_missing_ref(nil, %Scope{} = scope, key), do: runtime_read_ref(scope, key)
  defp resolve_missing_ref(value, _scope, _key), do: value

  defp resolve_not_loaded_ref(%Ash.NotLoaded{} = not_loaded, %Scope{} = scope, key) do
    exported_ref(scope, key, not_loaded)
  end

  # There are no exports: an unresolved bare ref is nil; a NotLoaded ref
  # keeps its fallback (the record is authoritative).
  defp runtime_read_ref(%Scope{} = _scope, _key), do: nil

  defp exported_ref(%Scope{} = _scope, _key, fallback), do: fallback

  defp resolve_runtime_param_values(value, scope) when is_list(value) do
    Enum.map(value, &resolve_runtime_param_values(&1, scope))
  end

  defp resolve_runtime_param_values({:__aliases__, _meta, parts}, _scope) when is_list(parts) do
    Module.concat(parts)
  end

  defp resolve_runtime_param_values({:%{}, _meta, pairs}, scope) when is_list(pairs) do
    Map.new(pairs, fn {key, value} -> {key, resolve_runtime_param_values(value, scope)} end)
  end

  defp resolve_runtime_param_values({key, value}, scope) when is_atom(key) or is_binary(key) do
    {key, resolve_runtime_param_values(value, scope)}
  end

  defp resolve_runtime_param_values(value, scope) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, item} -> {key, resolve_runtime_param_values(item, scope)} end)
  end

  defp resolve_runtime_param_values(%_{} = value, scope) do
    if expression?(value), do: eval!(value, scope), else: value
  end

  defp resolve_runtime_param_values(value, _scope)
       when is_atom(value) or is_binary(value) or is_number(value) or is_boolean(value) or
              is_nil(value),
       do: value

  defp resolve_runtime_param_values(value, scope), do: eval!(value, scope)

  defp evaluate_capability(action, bindings, record, scope) do
    case capability_subject(action, bindings, record) do
      nil ->
        false

      subject ->
        actor =
          scope.actor || Map.get(scope.context, :current_user) ||
            Map.get(scope.context, "current_user")

        capability_allowed?(subject, actor, scope.context)
    end
  rescue
    # broad rescue: capability expressions fail closed for arbitrary policy/Ash errors.
    _error -> false
  end

  defp capability_allowed?(subject, actor, context) do
    Ash.can?(subject, actor, context: context) ||
      domain_capability_allowed?(subject, actor)
  rescue
    # broad rescue: fallback to domain helper if the primary policy path fails.
    _error -> domain_capability_allowed?(subject, actor)
  end

  defp domain_capability_allowed?({subject, action}, actor)
       when (is_atom(subject) or is_struct(subject)) and is_atom(action) do
    with {:ok, domain} <- capability_domain(subject),
         helper when is_atom(helper) <- :"can_#{action}?",
         true <- function_exported?(domain, helper, capability_helper_arity(subject)) do
      apply(domain, helper, capability_helper_args(subject, actor))
    else
      _other -> false
    end
  rescue
    # broad rescue: domain capability helpers fail closed on arbitrary user/Ash exceptions.
    _error -> false
  end

  defp domain_capability_allowed?(_subject, _actor), do: false

  defp capability_domain(subject) when is_atom(subject),
    do: {:ok, Ash.Resource.Info.domain(subject)}

  defp capability_domain(%module{}), do: capability_domain(module)

  defp capability_helper_arity(subject) when is_atom(subject), do: 1
  defp capability_helper_arity(subject) when is_struct(subject), do: 2
  defp capability_helper_args(subject, actor) when is_atom(subject), do: [actor]
  defp capability_helper_args(subject, actor) when is_struct(subject), do: [actor, subject]

  defp capability_subject(action, bindings, record)
       when is_map(bindings) and map_size(bindings) == 0 and is_struct(record),
       do: {record, action}

  defp capability_subject(_action, bindings, _record)
       when is_map(bindings) and map_size(bindings) == 0,
       do: nil

  defp capability_subject(action, bindings, _record) when is_map(bindings) do
    cond do
      Map.has_key?(bindings, :resource) -> {Map.get(bindings, :resource), action}
      Map.has_key?(bindings, :record) -> {Map.get(bindings, :record), action}
      map_size(bindings) == 1 -> bindings |> Enum.at(0) |> elem(1) |> then(&{&1, action})
      true -> nil
    end
  end

  defp capability_subject(action, bindings, record) when is_list(bindings) do
    capability_subject(action, Enum.into(bindings, %{}), record)
  end

  defp capability_subject(action, _bindings, record) when is_struct(record), do: {record, action}
  defp capability_subject(_action, _bindings, _record), do: nil

  defp ast_call?({name, _meta, args}) when is_atom(name) and is_list(args), do: true
  defp ast_call?(_other), do: false
end
