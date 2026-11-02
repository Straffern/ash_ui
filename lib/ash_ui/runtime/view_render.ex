defmodule AshUi.Runtime.ViewRender do
  @moduledoc false

  alias AshUi.AttrMerge
  alias AshUi.EventBinding
  alias AshUi.Expr.Blank
  alias AshUi.Expr.Compiled, as: CompiledExpr
  alias AshUi.Expr.Eval, as: ExprEval
  alias AshUi.Expr.Scope, as: ExprScope
  alias AshUi.ResourceBlueprint, as: Resource
  alias AshUi.SafeHTML

  def render_view_node(resource, node, record, params, opts) when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    render_view_node(resource, node, record, params, opts)
  end

  def render_view_node(
        resource,
        %AshUi.RenderTree.Element{children: children} = node,
        record,
        params,
        opts
      ) do
    with {:ok, rendered_children} <-
           render_view_children(resource, children, record, params, opts) do
      {:ok, %{node | children: rendered_children}}
    end
  end

  def render_view_node(
        _resource,
        %AshUi.RenderTree.Text{} = node,
        _record,
        _params,
        _opts
      ) do
    {:ok, node}
  end

  def render_view_node(
        resource,
        %AshUi.RenderTree.Fragment{children: children} = node,
        record,
        params,
        opts
      ) do
    with {:ok, rendered_children} <-
           render_view_children(resource, children, record, params, opts) do
      {:ok, %{node | children: rendered_children}}
    end
  end

  def render_view_node(
        resource,
        %AshUi.RenderTree.Portal{target: {:computed, expr}},
        record,
        params,
        opts
      ) do
    with {:ok, computed} <- evaluate_value(expr, record, params, opts),
         {:ok, rendered} <- render_computed_result(resource, computed, record, params, opts) do
      {:ok, rendered}
    end
  rescue
    # broad rescue: computed portal rendering normalizes arbitrary expression/render failures.
    error ->
      {:error,
       AshUi.Runtime.Errors.normalize_runtime_reason(
         AshUi.Runtime.Errors.normalize_invoke_error(error)
       )}
  end

  def render_view_node(
        resource,
        %AshUi.RenderTree.Portal{children: children} = node,
        record,
        params,
        opts
      ) do
    with {:ok, rendered_children} <-
           render_view_children(resource, children, record, params, opts) do
      {:ok, %{node | children: rendered_children}}
    end
  end

  def render_view_node(resource, %{kind: :fragment, children: children}, record, params, opts) do
    Enum.reduce_while(children, {:ok, []}, fn child, {:ok, acc} ->
      case render_view_node(resource, child, record, params, opts) do
        {:ok, rendered_child} -> {:cont, {:ok, prepend_rendered_child(rendered_child, acc, opts)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rendered_children} ->
        {:ok, %{kind: :fragment, children: Enum.reverse(rendered_children)}}

      error ->
        error
    end
  end

  def render_view_node(resource, %{kind: kind, children: children} = node, record, params, opts)
      when kind in [:stack, :row] do
    Enum.reduce_while(children, {:ok, []}, fn child, {:ok, acc} ->
      case render_view_node(resource, child, record, params, opts) do
        {:ok, rendered_child} -> {:cont, {:ok, prepend_rendered_child(rendered_child, acc, opts)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rendered_children} ->
        {:ok,
         %{kind: kind, children: Enum.reverse(rendered_children)}
         |> maybe_put_part_options(Map.get(node, :options, %{}))}

      error ->
        error
    end
  end

  def render_view_node(_resource, %{kind: :text, content: content}, record, params, opts) do
    case evaluate_value(content, record, params, opts) do
      {:ok, %AshUi.RenderTree.Element{} = tree} -> {:ok, tree}
      {:ok, %AshUi.RenderTree.Text{} = tree} -> {:ok, tree}
      {:ok, %AshUi.RenderTree.Fragment{} = tree} -> {:ok, tree}
      {:ok, %AshUi.RenderTree.Portal{} = tree} -> {:ok, tree}
      {:ok, value} -> {:ok, %{kind: :text, content: render_text_value(value)}}
      error -> error
    end
  end

  def render_view_node(
        resource,
        %{kind: :when, condition: condition, child: child},
        record,
        params,
        opts
      ) do
    case evaluate_value(condition, record, params, opts) do
      {:ok, truthy} when truthy in [false, nil] -> {:ok, %{kind: :fragment, children: []}}
      {:ok, _truthy} -> render_view_node(resource, child, record, params, opts)
      error -> error
    end
  end

  def render_view_node(
        resource,
        %{kind: :if, condition: condition, then: then_child} = node,
        record,
        params,
        opts
      ) do
    case evaluate_value(condition, record, params, opts) do
      {:ok, truthy} when truthy in [false, nil] ->
        case Map.get(node, :else) do
          nil -> {:ok, %{kind: :fragment, children: []}}
          else_child -> render_view_node(resource, else_child, record, params, opts)
        end

      {:ok, _truthy} ->
        render_view_node(resource, then_child, record, params, opts)

      error ->
        error
    end
  end

  def render_view_node(
        resource,
        %{kind: :each, items: items, as: as, index: index_alias, child: child} = node,
        record,
        params,
        opts
      ) do
    source = items

    case evaluate_value(items, record, params, opts) do
      {:ok, evaluated_items} ->
        items =
          case evaluated_items do
            {:__ash_ui_singleton_value__, value} -> [value]
            value -> List.wrap(value)
          end

        opts =
          opts
          |> Map.put(:__bp_each_key__, Map.get(node, :key))
          |> Map.put(:__bp_each_source__, source)

        render_each_semantic(resource, child, items, as, index_alias, record, params, opts)

      error ->
        error
    end
  end

  def render_view_node(
        resource,
        %{
          kind: :element,
          tag: tag,
          attrs: attrs,
          events: events,
          states: states,
          children: children,
          meta: meta
        } = node,
        record,
        params,
        opts
      ) do
    authored_part = Map.get(node, :part)

    with {:ok, part_name} <- evaluate_optional_part_name(authored_part, record, params, opts),
         {:ok, evaluated_attrs} <- evaluate_assigns(attrs, record, params, opts),
         {:ok, evaluated_events} <- evaluate_event_bindings(events, record, params, opts),
         evaluated_attrs <- merge_field_errors(evaluated_attrs, events, opts),
         {:ok, active_part_states} <-
           evaluate_current_component_part_states(part_name, record, params, opts),
         {:ok, active_states} <- evaluate_node_states(states, record, params, opts) do
      with {:ok, client_actions} <-
             evaluate_client_actions_for_part(tag, part_name, record, params, opts),
           {:ok, client_runtimes} <-
             evaluate_client_runtimes_for_part(part_name, record, params, opts) do
        Enum.reduce_while(children, {:ok, []}, fn child, {:ok, acc} ->
          case render_view_node(resource, child, record, params, opts) do
            {:ok, rendered_child} ->
              {:cont, {:ok, prepend_rendered_child(rendered_child, acc, opts)}}

            error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, rendered_children} ->
            {:ok,
             %{
               kind: :element,
               tag: tag,
               attrs:
                 AttrMerge.merge_attr_sources(
                   evaluated_attrs,
                   %{},
                   adapter_attrs(client_actions, client_runtimes, meta)
                 ),
               events: evaluated_events,
               children: Enum.reverse(rendered_children),
               meta:
                 meta
                 |> put_component_part_meta(
                   nil,
                   part_name,
                   Enum.uniq(active_part_states ++ active_states)
                 )
                 |> maybe_put_client_actions_meta(client_actions)
                 |> maybe_put_client_runtimes_meta(client_runtimes)
                 |> put_patch_address(node, opts)
                 |> put_binding_chain(node, evaluated_events, opts)
             }}

          error ->
            error
        end
      end
    end
  end

  def render_view_node(
        resource,
        %{kind: :computed, expr: expr},
        record,
        params,
        opts
      ) do
    with {:ok, computed} <- evaluate_value(expr, record, params, opts),
         {:ok, rendered} <- render_computed_result(resource, computed, record, params, opts) do
      {:ok, rendered}
    end
  rescue
    # broad rescue: computed component rendering normalizes arbitrary expression/render failures.
    error ->
      {:error,
       AshUi.Runtime.Errors.normalize_runtime_reason(
         AshUi.Runtime.Errors.normalize_invoke_error(error)
       )}
  end

  def render_view_node(
        resource,
        %{kind: :attached_view} = node,
        record,
        params,
        opts
      ) do
    render_attached_view(resource, node, record, params, opts)
  end

  def render_view_node(
        resource,
        %{kind: :resource_component} = node,
        record,
        params,
        opts
      ) do
    AshUi.Runtime.ResourceComponentRender.render(resource, node, record, params, opts)
  end

  def render_attached_view(resource, node, record, params, opts) when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    render_attached_view(resource, node, record, params, opts)
  end

  def render_attached_view(resource, %{child: child} = node, record, params, opts) do
    with {:ok, evaluated_client_actions} <-
           evaluate_client_actions(Map.get(node, :client, []), record, params, opts),
         {:ok, evaluated_client_runtimes} <-
           evaluate_client_runtimes(Map.get(node, :runtimes, []), record, params, opts) do
      render_view_node(
        resource,
        child,
        record,
        params,
        merge_client_attachment_opts(opts, evaluated_client_actions, evaluated_client_runtimes)
      )
    end
  end

  def render_view_children(resource, children, record, params, opts) when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    render_view_children(resource, children, record, params, opts)
  end

  def render_view_children(resource, children, record, params, opts) do
    Enum.reduce_while(children, {:ok, []}, fn child, {:ok, acc} ->
      case render_view_node(resource, child, record, params, opts) do
        {:ok, rendered_child} -> {:cont, {:ok, prepend_rendered_child(rendered_child, acc, opts)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rendered_children} -> {:ok, Enum.reverse(rendered_children)}
      error -> error
    end
  end

  def prepend_rendered_child(rendered_child, acc) do
    prepend_rendered_child(rendered_child, acc, %{})
  end

  def prepend_rendered_child(rendered_child, acc, opts) when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    prepend_rendered_child(rendered_child, acc, opts)
  end

  def prepend_rendered_child(%{kind: :fragment, children: []} = rendered_child, acc, opts) do
    if Map.get(opts, :preserve_empty_fragments?, false) do
      [rendered_child | acc]
    else
      acc
    end
  end

  def prepend_rendered_child(rendered_child, acc, _opts) do
    [rendered_child | acc]
  end

  def render_computed_result(resource, computed, record, params, opts) when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    render_computed_result(resource, computed, record, params, opts)
  end

  def render_computed_result(_resource, nil, _record, _params, _opts) do
    {:ok, %{kind: :fragment, children: []}}
  end

  def render_computed_result(resource, computed, record, params, opts) when is_list(computed) do
    computed
    |> Enum.reduce_while({:ok, []}, fn child, {:ok, acc} ->
      case render_computed_result(resource, child, record, params, opts) do
        {:ok, %{kind: :fragment, children: children}} ->
          {:cont, {:ok, Enum.reverse(children) ++ acc}}

        {:ok, rendered_child} ->
          {:cont, {:ok, [rendered_child | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, children} -> {:ok, %{kind: :fragment, children: Enum.reverse(children)}}
      error -> error
    end
  end

  def render_computed_result(resource, %{kind: _kind} = computed, record, params, opts) do
    render_view_node(resource, computed, record, params, opts)
  end

  def render_computed_result(
        _resource,
        %AshUi.RenderTree.Element{} = computed,
        _record,
        _params,
        _opts
      ) do
    {:ok, computed}
  end

  def render_computed_result(
        _resource,
        %AshUi.RenderTree.Text{} = computed,
        _record,
        _params,
        _opts
      ) do
    {:ok, computed}
  end

  def render_computed_result(
        _resource,
        %AshUi.RenderTree.Fragment{} = computed,
        _record,
        _params,
        _opts
      ) do
    {:ok, computed}
  end

  def render_computed_result(
        _resource,
        %AshUi.RenderTree.Portal{} = computed,
        _record,
        _params,
        _opts
      ) do
    {:ok, computed}
  end

  def render_computed_result(_resource, computed, _record, _params, _opts)
      when is_binary(computed) or is_number(computed) or is_boolean(computed) do
    {:ok, %{kind: :text, content: to_string(computed)}}
  end

  def render_computed_result(_resource, computed, _record, _params, _opts) do
    if Blank.blank?(computed) do
      {:ok, %{kind: :text, content: ""}}
    else
      {:error, {:invalid_computed_result, computed}}
    end
  end

  def render_each_semantic(_resource, _child, [], _as, _index_alias, _record, _params, _opts) do
    {:ok, %{kind: :fragment, children: []}}
  end

  def render_each_semantic(resource, child, items, as, index_alias, record, params, opts)
      when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    render_each_semantic(resource, child, items, as, index_alias, record, params, opts)
  end

  def render_each_semantic(resource, child, items, as, index_alias, record, params, opts)
      when is_map(opts) do
    prepared_child = prepare_each_child(resource, child)
    {key_expr, opts} = Map.pop(opts, :__bp_each_key__)
    {source, opts} = Map.pop(opts, :__bp_each_source__)
    source_path = expression_path(source, opts)
    item_bindings = Map.get(opts, :item_bindings, %{})
    index_bindings = Map.get(opts, :index_bindings, %{})
    chain = Map.get(opts, :__bp_chain__, [])
    item_paths = Map.get(opts, :__bp_item_paths__, %{})

    items
    |> Enum.reduce_while({:ok, [], 0}, fn item, {:ok, acc, index} ->
      scoped_params = Map.put(params, as, item)

      # ONE identity rule (Patch.Keys): the authored key: wins, evaluated
      # with the item in scope — the SAME identity the resolver computes.
      entry_key = each_entry_key(key_expr, item, index, as, record, scoped_params, opts)

      entry_component = AshUi.EventBinding.key_component(entry_key)

      scoped_opts =
        opts
        |> Map.put(:item_bindings, Map.put(item_bindings, as, item))
        |> Map.put(:index_bindings, Map.put(index_bindings, index_alias, index))
        |> Map.put(:__bp_chain__, chain ++ [entry_component])
        |> put_item_path(item_paths, as, source_path, index)

      rendered_result =
        render_prepared_each_child(resource, prepared_child, record, scoped_params, scoped_opts)

      case rendered_result do
        {:ok, rendered_child} ->
          keyed_child = maybe_put_render_key(rendered_child, entry_key)

          {:cont, {:ok, [keyed_child | acc], index + 1}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, rendered_children, _index} ->
        {:ok, %{kind: :fragment, children: Enum.reverse(rendered_children)}}

      error ->
        error
    end
  end

  defp prepare_each_child(_resource, node), do: {:node, node}

  defp render_prepared_each_child(resource, {:node, node}, record, params, opts) do
    render_view_node(resource, node, record, params, opts)
  end

  def evaluate_assigns(assigns, record, params, opts) when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    evaluate_assigns(assigns, record, params, opts)
  end

  def evaluate_assigns(assigns, record, params, opts) when is_map(assigns) do
    if map_size(assigns) == 0 do
      {:ok, %{}}
    else
      profile_span(opts, {:evaluate_assigns, :map}, fn ->
        Enum.reduce_while(assigns, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
          case evaluate_assign_value(value, record, params, opts) do
            {:ok, evaluated} -> {:cont, {:ok, Map.put(acc, key, evaluated)}}
            error -> {:halt, error}
          end
        end)
      end)
    end
  end

  def evaluate_assigns([], _record, _params, _opts), do: {:ok, %{}}

  def evaluate_assigns(assigns, record, params, opts) when is_list(assigns) do
    profile_span(opts, {:evaluate_assigns, :list}, fn ->
      Enum.reduce_while(assigns, {:ok, %{}}, fn
        %{kind: :put, key: key, from: value, optional?: optional?}, {:ok, acc} ->
          case evaluate_assign_value(value, record, params, opts) do
            {:ok, nil} when optional? -> {:cont, {:ok, acc}}
            {:ok, evaluated} -> {:cont, {:ok, Map.put(acc, key, evaluated)}}
            error -> {:halt, error}
          end

        {key, value}, {:ok, acc} ->
          case evaluate_assign_value(value, record, params, opts) do
            {:ok, evaluated} -> {:cont, {:ok, Map.put(acc, key, evaluated)}}
            error -> {:halt, error}
          end

        other, _acc ->
          {:halt, {:error, {:invalid_assign_entry, other}}}
      end)
    end)
  end

  def materialize_fragment_value(value, resource, record, params, opts)
      when is_atom(resource) and (is_list(opts) or is_map(opts)) do
    compiled = AshUi.Runtime.ResourceInfo.compiled_resource(resource)

    AshUi.Runtime.Rendering.render_tree(
      %{compiled | view: value},
      record,
      params,
      opts
    )
  end

  defp evaluate_assign_value(%{kind: kind} = value, record, params, opts)
       when kind in [
              :attached_view,
              :computed,
              :each,
              :element,
              :fragment,
              :if,
              :resource_component,
              :text,
              :when
            ] do
    resource =
      get_in(opts, [:context, :__blueprint_resource__]) ||
        AshUi.Runtime.ResourceInfo.compiled_resource(record.__struct__)

    with {:ok, rendered} <- render_view_node(resource, value, record, params, opts),
         {:ok, tree} <- AshUi.RenderTree.render(rendered) do
      {:ok, tree}
    end
  end

  defp evaluate_assign_value(value, record, params, opts) do
    evaluate_value(value, record, params, opts)
  end

  def evaluate_event_bindings(events, _record, _params, _opts) when events in [[], nil],
    do: {:ok, []}

  def evaluate_event_bindings(events, record, params, opts) when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    evaluate_event_bindings(events, record, params, opts)
  end

  def evaluate_event_bindings(events, record, params, opts) when is_map(opts) do
    profile_span(opts, :evaluate_event_bindings, fn ->
      Enum.reduce_while(events, {:ok, []}, fn %EventBinding{} = binding, {:ok, acc} ->
        case evaluate_expanded_event_bindings([binding], record, params, opts) do
          {:ok, evaluated_bindings} -> {:cont, {:ok, evaluated_bindings ++ acc}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, evaluated_events} -> {:ok, Enum.reverse(evaluated_events)}
        error -> error
      end
    end)
  end

  defp evaluate_expanded_event_bindings(bindings, record, params, opts) when is_list(bindings) do
    Enum.reduce_while(bindings, {:ok, []}, fn %EventBinding{} = binding, {:ok, acc} ->
      case evaluate_assigns(binding.args_exprs, record, params, opts) do
        {:ok, evaluated_args} ->
          evaluated_binding = %{binding | args_exprs: evaluated_args}

          {:cont, {:ok, [evaluated_binding | acc]}}

        error ->
          {:halt, error}
      end
    end)
  end

  def evaluate_node_states(states, _record, _params, _opts) when states in [nil, []] do
    {:ok, []}
  end

  def evaluate_node_states(states, record, params, opts)
      when is_list(states) and is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    evaluate_node_states(states, record, params, opts)
  end

  def evaluate_node_states(states, record, params, opts)
      when is_list(states) and is_map(opts) do
    profile_span(opts, {:evaluate_node_states, Enum.map(states, & &1.name)}, fn ->
      Enum.reduce_while(states, {:ok, []}, fn %{name: state_name, when: condition}, {:ok, acc} ->
        case evaluate_value(condition, record, params, opts) do
          {:ok, truthy} when truthy in [false, nil] -> {:cont, {:ok, acc}}
          {:ok, _truthy} -> {:cont, {:ok, [state_name | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, states} -> {:ok, Enum.reverse(states)}
        error -> error
      end
    end)
  end

  def put_component_part_meta(meta, _component_name, nil, []) do
    meta
  end

  def put_component_part_meta(meta, _component_name, nil, states) do
    Map.put(meta, :node_states, states)
  end

  def put_component_part_meta(meta, component_name, part_name, states) do
    meta
    |> Map.put(:component_part, part_name)
    |> Map.put(:component, component_name)
    |> Map.put(:component_part_states, states)
  end

  def evaluate_client_actions(actions, _record, _params, _opts) when actions in [[], nil] do
    {:ok, []}
  end

  def evaluate_client_actions(actions, record, params, opts)
      when is_list(actions) and is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    evaluate_client_actions(actions, record, params, opts)
  end

  def evaluate_client_actions(actions, record, params, opts)
      when is_list(actions) and is_map(opts) do
    Enum.reduce_while(actions, {:ok, []}, fn action, {:ok, acc} ->
      case evaluate_assigns(Map.get(action, :opts, %{}), record, params, opts) do
        {:ok, evaluated_opts} ->
          evaluated_action =
            action
            |> Map.put(:opts, evaluated_opts)

          {:cont, {:ok, [evaluated_action | acc]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, evaluated_actions} -> {:ok, Enum.reverse(evaluated_actions)}
      error -> error
    end
  end

  def evaluate_client_runtimes(runtimes, _record, _params, _opts) when runtimes in [[], nil] do
    {:ok, []}
  end

  def evaluate_client_runtimes(runtimes, record, params, opts)
      when is_list(runtimes) and is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    evaluate_client_runtimes(runtimes, record, params, opts)
  end

  def evaluate_client_runtimes(runtimes, record, params, opts)
      when is_list(runtimes) and is_map(opts) do
    Enum.reduce_while(runtimes, {:ok, []}, fn runtime, {:ok, acc} ->
      case evaluate_assigns(Map.get(runtime, :opts, %{}), record, params, opts) do
        {:ok, evaluated_opts} -> {:cont, {:ok, [%{runtime | opts: evaluated_opts} | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, evaluated_runtimes} -> {:ok, Enum.reverse(evaluated_runtimes)}
      error -> error
    end
  end

  def evaluate_client_actions_for_part(_tag, nil, _record, _params, _opts) do
    {:ok, []}
  end

  def evaluate_client_actions_for_part(tag, part_name, record, params, opts)
      when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    evaluate_client_actions_for_part(tag, part_name, record, params, opts)
  end

  def evaluate_client_actions_for_part(tag, part_name, record, params, opts)
      when is_map(opts) do
    caller_client_actions =
      opts |> Map.get(:client_actions_by_part, %{}) |> Map.get(part_name, [])

    part_client_actions =
      opts |> Map.get(:action_client_actions_by_part, %{}) |> Map.get(part_name, [])

    if caller_client_actions in [[], nil] and part_client_actions == [] do
      {:ok, []}
    else
      client_actions = List.wrap(caller_client_actions) ++ part_client_actions

      profile_span(opts, :evaluate_client_actions_for_part, fn ->
        client_actions
        |> evaluate_client_actions(record, params, opts)
        |> case do
          {:ok, evaluated_actions} ->
            {:ok,
             Enum.map(evaluated_actions, fn action ->
               if is_nil(action.using) and is_nil(action.dom_event) do
                 EventBinding.put_client_dom_event(action, EventBinding.infer_dom_event(tag))
               else
                 action
               end
             end)}

          error ->
            error
        end
      end)
    end
  end

  def action_client_actions_by_part(%Resource{} = resource) do
    resource
    |> Map.get(:actions, [])
    |> Enum.flat_map(&Map.get(&1, :client_actions, []))
    |> Enum.group_by(& &1.target)
  end

  def evaluate_client_runtimes_for_part(nil, _record, _params, _opts) do
    {:ok, []}
  end

  def evaluate_client_runtimes_for_part(part_name, record, params, opts) when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    evaluate_client_runtimes_for_part(part_name, record, params, opts)
  end

  def evaluate_client_runtimes_for_part(part_name, record, params, opts) when is_map(opts) do
    client_runtimes = opts |> Map.get(:client_runtimes_by_part, %{}) |> Map.get(part_name, [])

    if client_runtimes in [[], nil] do
      {:ok, []}
    else
      profile_span(opts, :evaluate_client_runtimes_for_part, fn ->
        client_runtimes |> evaluate_client_runtimes(record, params, opts)
      end)
    end
  end

  def adapter_attrs([], [], meta) when is_map(meta) do
    if Map.has_key?(meta, :dom_owner) or Map.has_key?(meta, :reorder) do
      adapter_attrs_with_clients([], [], meta)
    else
      %{}
    end
  end

  def adapter_attrs(client_actions, client_runtimes, meta) do
    adapter_attrs_with_clients(client_actions, client_runtimes, meta)
  end

  def adapter_attrs_with_clients(client_actions, client_runtimes, meta) do
    {client_actions, client_runtimes} =
      EventBinding.merge_reorder_client_entities(client_actions, client_runtimes, meta)

    %{}
    |> put_client_action_attrs(client_actions)
    |> put_client_runtime_attrs(client_runtimes)
    |> put_dom_owner_attrs(meta)
  end

  def maybe_put_client_actions_meta(meta, []) do
    meta
  end

  def maybe_put_client_actions_meta(meta, client_actions) do
    Map.put(meta, :client_actions, client_actions)
  end

  def maybe_put_client_runtimes_meta(meta, []) do
    meta
  end

  def maybe_put_client_runtimes_meta(meta, client_runtimes) do
    Map.put(meta, :client_runtimes, client_runtimes)
  end

  def put_client_action_attrs(attrs, []) do
    attrs
  end

  def put_client_action_attrs(attrs, client_actions) do
    serialized_actions =
      client_actions |> Enum.map(&EventBinding.serialize_client_action/1) |> Enum.uniq()

    attrs
    |> Map.put("data-ash-ui-client-actions", Jason.encode!(serialized_actions))
    |> Map.put_new("data-ash-ui-client-hook", "AshUiClient")
  end

  def put_client_runtime_attrs(attrs, []) do
    attrs
  end

  def put_client_runtime_attrs(attrs, client_runtimes) do
    attrs
    |> Map.put(
      "data-ash-ui-client-runtimes",
      Jason.encode!(Enum.map(client_runtimes, &EventBinding.serialize_client_runtime/1))
    )
    |> Map.put_new("data-ash-ui-client-hook", "AshUiClient")
  end

  def put_dom_owner_attrs(attrs, meta) do
    case Map.get(meta, :dom_owner) do
      nil ->
        attrs

      value when is_atom(value) ->
        Map.put(attrs, "data-ash-ui-dom-owner", Atom.to_string(value))

      value ->
        Map.put(attrs, "data-ash-ui-dom-owner", value)
    end
  end

  def merge_client_attachment_opts(opts, client_actions, client_runtimes) when is_list(opts) do
    opts
    |> Keyword.update(:client_actions, client_actions, &(&1 ++ client_actions))
    |> Keyword.update(:client_runtimes, client_runtimes, &(&1 ++ client_runtimes))
    |> Keyword.update(
      :client_actions_by_part,
      group_client_entities_by_target(client_actions),
      &merge_grouped_client_entities(&1, client_actions)
    )
    |> Keyword.update(
      :client_runtimes_by_part,
      group_client_entities_by_target(client_runtimes),
      &merge_grouped_client_entities(&1, client_runtimes)
    )
  end

  def merge_client_attachment_opts(opts, client_actions, client_runtimes) when is_map(opts) do
    client_actions_by_part = group_client_entities_by_target(client_actions)
    client_runtimes_by_part = group_client_entities_by_target(client_runtimes)

    opts
    |> Map.update(:client_actions, client_actions, &(&1 ++ client_actions))
    |> Map.update(:client_runtimes, client_runtimes, &(&1 ++ client_runtimes))
    |> Map.update(
      :client_actions_by_part,
      client_actions_by_part,
      &merge_grouped_client_entity_maps(&1, client_actions_by_part)
    )
    |> Map.update(
      :client_runtimes_by_part,
      client_runtimes_by_part,
      &merge_grouped_client_entity_maps(&1, client_runtimes_by_part)
    )
  end

  def put_grouped_client_opts(opts) when is_list(opts) do
    opts
    |> Keyword.put_new_lazy(:client_actions_by_part, fn ->
      group_client_entities_by_target(Keyword.get(opts, :client_actions, []))
    end)
    |> Keyword.put_new_lazy(:client_runtimes_by_part, fn ->
      group_client_entities_by_target(Keyword.get(opts, :client_runtimes, []))
    end)
  end

  def put_grouped_client_opts(opts) when is_map(opts) do
    opts
    |> Map.put_new(
      :client_actions_by_part,
      group_client_entities_by_target(Map.get(opts, :client_actions, []))
    )
    |> Map.put_new(
      :client_runtimes_by_part,
      group_client_entities_by_target(Map.get(opts, :client_runtimes, []))
    )
  end

  def group_client_entities_by_target(entities) do
    entities |> List.wrap() |> Enum.group_by(&EventBinding.client_target/1)
  end

  def merge_grouped_client_entities(grouped, entities) when is_map(grouped) do
    merge_grouped_client_entity_maps(grouped, group_client_entities_by_target(entities))
  end

  defp merge_grouped_client_entity_maps(grouped, next_grouped) do
    Map.merge(next_grouped, grouped, fn _target, next_entities, existing_entities ->
      existing_entities ++ next_entities
    end)
  end

  def evaluate_optional_part_name(nil, _record, _params, _opts), do: {:ok, nil}

  def evaluate_optional_part_name(part_name, _record, _params, _opts)
      when is_atom(part_name) or is_binary(part_name),
      do: {:ok, part_name}

  def evaluate_optional_part_name(part_name, record, params, opts) do
    case evaluate_value(part_name, record, params, opts) do
      {:ok, value} when is_atom(value) or is_binary(value) or is_nil(value) ->
        {:ok, value}

      {:ok, other} ->
        {:error, {:invalid_component_part, other}}

      error ->
        error
    end
  end

  # DESIGN.md §9 splits structure and paint: a view part contributes only
  # its bare name to the emitted `part` attribute.

  def evaluate_value(value, _record, _params, _opts)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
    {:ok, value}
  end

  def evaluate_value({:safe, _iodata} = value, _record, _params, _opts) do
    {:ok, value}
  end

  def evaluate_value(%SafeHTML{} = value, _record, _params, _opts) do
    {:ok, value}
  end

  def evaluate_value(%CompiledExpr{} = value, record, params, opts) do
    {:ok, ExprEval.eval!(value, expr_scope(record, params, opts))}
  rescue
    # broad rescue: runtime expression value evaluation returns arbitrary failures as tagged errors.
    error -> {:error, error}
  end

  def evaluate_value(%_{} = value, record, params, opts) do
    ExprEval.eval(value, expr_scope(record, params, opts))
  end

  def evaluate_value(value, record, params, opts) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
      case evaluate_value(item, record, params, opts) do
        {:ok, evaluated} -> {:cont, {:ok, [evaluated | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, evaluated_list} -> {:ok, Enum.reverse(evaluated_list)}
      error -> error
    end
  end

  def evaluate_value(value, record, params, opts) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      case evaluate_value(item, record, params, opts) do
        {:ok, evaluated} -> {:cont, {:ok, Map.put(acc, key, evaluated)}}
        error -> {:halt, error}
      end
    end)
  end

  def evaluate_value(value, record, params, opts) do
    ExprEval.eval(value, expr_scope(record, params, opts))
  end

  defp render_text_value(value) do
    if Blank.blank?(value), do: "", else: value
  end

  def put_expr_scope_base(opts, record, params) when is_list(opts) and is_map(params) do
    opts_without_base = Keyword.delete(opts, :expr_scope_base)
    Keyword.put(opts, :expr_scope_base, ExprScope.new(record, params, opts_without_base))
  end

  def put_expr_scope_base(opts, record, params) when is_map(opts) and is_map(params) do
    Map.put(
      opts,
      :expr_scope_base,
      ExprScope.new(record, params, Map.delete(opts, :expr_scope_base))
    )
  end

  @doc false
  def expression_path(%CompiledExpr{ir: ir}, opts), do: expression_path(ir, opts)

  def expression_path({:_ref, path, field}, _opts) when is_list(path) and is_atom(field),
    do: path ++ [field]

  def expression_path({:_item, binding, path}, opts)
      when is_atom(binding) and is_list(path) and is_map(opts) do
    case opts |> Map.get(:__bp_item_paths__, %{}) |> Map.get(binding) do
      base when is_list(base) -> base ++ path
      _missing -> nil
    end
  end

  def expression_path({:_item, binding, path}, opts)
      when is_atom(binding) and is_list(path) and is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    expression_path({:_item, binding, path}, opts)
  end

  def expression_path(_expression, _opts), do: nil

  @doc false
  def put_error_scope(opts, path) when is_list(opts) do
    errors = Keyword.get(opts, :__bp_all_errors__, Keyword.get(opts, :errors, []))

    opts
    |> Keyword.put(:__bp_all_errors__, errors)
    |> Keyword.put(:__bp_error_path__, path)
    |> Keyword.put(:errors, errors_at_path(errors, path))
  end

  def put_error_scope(opts, path) when is_map(opts) do
    errors = Map.get(opts, :__bp_all_errors__, Map.get(opts, :errors, []))

    opts
    |> Map.put(:__bp_all_errors__, errors)
    |> Map.put(:__bp_error_path__, path)
    |> Map.put(:errors, errors_at_path(errors, path))
  end

  @doc false
  def errors_at_path(errors, path) when is_list(path) do
    Enum.filter(List.wrap(errors), fn error ->
      error_path = List.wrap(Map.get(error, :path))

      if path == [] do
        error_path == []
      else
        Enum.take(error_path, length(path)) == path
      end
    end)
  end

  def errors_at_path(_errors, _path), do: []

  defp put_item_path(opts, _item_paths, _as, nil, _index), do: opts

  defp put_item_path(opts, item_paths, as, source_path, index) do
    Map.put(opts, :__bp_item_paths__, Map.put(item_paths, as, source_path ++ [index]))
  end

  def expr_scope(record, params, opts) when is_map(opts) do
    case Map.get(opts, :expr_scope_base) do
      %ExprScope{} = base -> ExprScope.for_eval(base, record, params, opts)
      _other -> ExprScope.new(record, params, opts)
    end
  end

  def expr_scope(record, params, opts) when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    expr_scope(record, params, opts)
  end

  def evaluate_current_component_part_states(nil, _record, _params, _opts) do
    {:ok, []}
  end

  def evaluate_current_component_part_states(part_name, _record, _params, _opts)
      when is_atom(part_name),
      do: {:ok, []}

  def evaluate_component_part_states(states, record, params, opts)
      when is_list(states) and is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    evaluate_component_part_states(states, record, params, opts)
  end

  def evaluate_component_part_states(states, record, params, opts)
      when is_list(states) and is_map(opts) do
    states
    |> Enum.reduce_while({:ok, []}, fn %{name: state_name, when: condition}, {:ok, acc} ->
      case evaluate_value(condition, record, params, opts) do
        {:ok, truthy} when truthy in [false, nil] -> {:cont, {:ok, acc}}
        {:ok, _truthy} -> {:cont, {:ok, [state_name | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state_names} -> {:ok, Enum.reverse(state_names)}
      error -> error
    end
  end

  def maybe_put_render_key(%{kind: kind} = child, key)
      when kind in [:element, :fragment, :text, :component, :when] do
    Map.put(child, :key, key)
  end

  def maybe_put_render_key(child, _key) do
    child
  end

  def maybe_put_part_options(node, options) when is_map(options) and map_size(options) > 0 do
    Map.put(node, :options, options)
  end

  def maybe_put_part_options(node, _options) do
    node
  end

  def profile_span(_opts, _label, fun) when is_function(fun, 0) do
    fun.()
  end

  # ONE key language: binding keys = runtime chain (item keys, child addrs)
  # + the element's stamped lowered address. Every render target emits the
  # same keys the registration-free resolver accepts.
  # Preserve the compiled, target-neutral identity on every materialized
  # element. Event-bearing elements already exposed it through their binding
  # chain; non-event dynamic boundaries need the same address for render
  # targets that patch complete HTML elements.
  defp put_patch_address(meta, node, opts) do
    case Map.get(node, :__bp_addr__) do
      nil ->
        meta

      addr ->
        meta
        |> Map.put(:__bp_addr__, addr)
        |> Map.put(:__bp_runtime_chain__, Map.get(opts, :__bp_chain__, []))
    end
  end

  defp put_binding_chain(meta, _node, [], _opts), do: meta

  defp put_binding_chain(meta, node, _events, opts) do
    case Map.get(node, :__bp_addr__) do
      nil ->
        meta

      addr ->
        chain =
          Map.get(opts, :__bp_chain__, []) ++
            [AshUi.Patch.Compiler.addr_component(addr)]

        Map.put(meta, :__bp_binding_chain__, chain)
    end
  end

  defp each_entry_key(nil, item, index, _as, _record, _params, _opts) do
    AshUi.Patch.Keys.entry_key(item, index)
  end

  defp each_entry_key(key_expr, item, index, as, record, params, opts) do
    scoped_opts =
      Map.update(opts, :item_bindings, %{as => item}, &Map.put(&1, as, item))

    case evaluate_value(key_expr, record, params, scoped_opts) do
      {:ok, value} when not is_nil(value) -> value
      _other -> AshUi.Patch.Keys.entry_key(item, index)
    end
  end

  # Automatic error distribution (DESIGN.md §5): a failed action's field-path'd
  # errors land on the elements BOUND to those field names — ARIA-first
  # (aria-invalid) plus the message in the neutral vocabulary. ONE render
  # path: both the semantic renderer and the live attrs evaluators pass
  # through here, so the byte oracle holds with errors present.
  defp merge_field_errors(attrs, events, opts) do
    errors = Map.get(opts, :errors, [])

    bound =
      case {List.wrap(events), Map.get(attrs, "name") || Map.get(attrs, :name)} do
        {[_ | _], name} when is_atom(name) and not is_nil(name) ->
          [name]

        {[_ | _], name} when is_binary(name) and name != "" ->
          try do
            [String.to_existing_atom(name)]
          rescue
            ArgumentError -> []
          end

        _unnamed ->
          bound_field_names(events)
      end

    messages =
      if errors == [] or bound == [] do
        []
      else
        errors
        |> List.wrap()
        |> Enum.filter(&(AshUi.Runtime.Errors.field(&1) in bound))
        |> Enum.map(&AshUi.Runtime.Errors.message/1)
      end

    if messages == [] do
      attrs
    else
      attrs
      |> Map.put("aria-invalid", "true")
      |> Map.put("data-ash-ui-error", Enum.join(messages, "; "))
    end
  end

  defp bound_field_names(events) do
    events
    |> List.wrap()
    |> Enum.flat_map(fn binding ->
      case Map.get(binding, :args_exprs) do
        %{} = args -> Map.keys(args)
        _other -> []
      end
    end)
    |> Enum.uniq()
  end
end
