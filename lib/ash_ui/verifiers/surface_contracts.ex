defmodule AshUi.Verifiers.SurfaceContracts do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Ash.Query.{Call, Ref}
  alias AshUi.EventBinding
  alias AshUi.Expr.Compiled
  alias AshUi.Verifiers.Helpers

  @impl true
  def verify(dsl_state) do
    resource = Helpers.compiled_resource!(dsl_state)

    result = verify_view(dsl_state, resource)

    case result do
      {:error, error} -> raise error
      :ok -> maybe_warn(if_else_hint_warnings(resource))
      other -> other
    end
  end

  defp maybe_warn([]), do: :ok
  defp maybe_warn(warnings), do: {:warn, warnings}

  defp if_else_hint_warnings(resource) do
    collect_if_else_hint_warnings(resource.view, [:view])
  end

  defp collect_if_else_hint_warnings(nil, _path), do: []

  defp collect_if_else_hint_warnings(%{kind: :fragment, children: children}, path) do
    sibling_if_else_hint_warnings(children, path) ++
      collect_if_else_hint_child_warnings(children, path)
  end

  defp collect_if_else_hint_warnings(%{kind: kind, children: children}, path)
       when kind in [:stack, :row, :element, :part] do
    sibling_if_else_hint_warnings(children, path) ++
      collect_if_else_hint_child_warnings(children, path)
  end

  defp collect_if_else_hint_warnings(%{kind: :if, then: then_child} = node, path) do
    collect_if_else_hint_warnings(then_child, path ++ [:if, :then]) ++
      collect_if_else_hint_warnings(Map.get(node, :else), path ++ [:if, :else])
  end

  defp collect_if_else_hint_warnings(%{kind: :when, child: child}, path) do
    collect_if_else_hint_warnings(child, path ++ [:when])
  end

  defp collect_if_else_hint_warnings(%{kind: :each, child: child}, path) do
    collect_if_else_hint_warnings(child, path ++ [:each])
  end

  defp collect_if_else_hint_warnings(%{kind: :attached_view, child: child}, path) do
    collect_if_else_hint_warnings(child, path ++ [:attached_view])
  end

  defp collect_if_else_hint_warnings(%{kind: :resource_component, assigns: assigns}, path)
       when is_map(assigns) do
    Enum.flat_map(assigns, fn {name, value} ->
      if fragment_value?(value) do
        collect_if_else_hint_warnings(value, path ++ [:assigns, name])
      else
        []
      end
    end)
  end

  defp collect_if_else_hint_warnings(_node, _path), do: []

  defp collect_if_else_hint_child_warnings(children, path) when is_list(children) do
    children
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} ->
      collect_if_else_hint_warnings(child, path ++ [index])
    end)
  end

  defp sibling_if_else_hint_warnings(children, path) when is_list(children) do
    children
    |> Enum.with_index()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [{left, index}, {right, _next_index}] ->
        if complementary_if_blocks?(left, right) do
          [
            {"#{inspect(path ++ [index])}: complementary sibling if blocks detected; use one if/else expression",
             nil}
          ]
        else
          []
        end
    end)
  end

  defp complementary_if_blocks?(left, right) do
    with {:ok, left_condition} <- if_without_else_condition(left),
         {:ok, right_condition} <- if_without_else_condition(right) do
      exact_negation?(left_condition, right_condition) or
        exact_negation?(right_condition, left_condition)
    else
      _other -> false
    end
  end

  defp if_without_else_condition(%{kind: :if, condition: %Compiled{} = condition} = node) do
    if empty_fragment?(Map.get(node, :else)) do
      {:ok, condition}
    else
      :error
    end
  end

  defp if_without_else_condition(_node), do: :error

  defp empty_fragment?(nil), do: true
  defp empty_fragment?(%{kind: :fragment, children: []}), do: true
  defp empty_fragment?(_node), do: false

  defp exact_negation?(%Compiled{ir: %Ash.Query.Not{expression: inner}}, %Compiled{ir: ir}) do
    inner == ir
  end

  defp exact_negation?(_left, _right), do: false

  defp verify_view(_dsl_state, %{view: nil}), do: :ok

  defp verify_view(dsl_state, resource) do
    verify_view_node(
      dsl_state,
      resource,
      resource.view,
      [:view],
      resource_template_scope(resource)
      |> put_store_owner(resource.module)
    )
  end

  defp verify_view_node(
         dsl_state,
         resource,
         %{kind: :fragment, children: children},
         path,
         scope
       ) do
    Helpers.verify_each(Enum.with_index(children), fn {child, index} ->
      verify_view_node(dsl_state, resource, child, path ++ [index], scope)
    end)
  end

  defp verify_view_node(
         dsl_state,
         resource,
         %{kind: kind, children: children},
         path,
         scope
       )
       when kind in [:stack, :row] do
    Helpers.verify_each(Enum.with_index(children), fn {child, index} ->
      verify_view_node(dsl_state, resource, child, path ++ [kind, index], scope)
    end)
  end

  defp verify_view_node(
         dsl_state,
         resource,
         %{kind: kind, children: children, events: events} = node,
         path,
         scope
       )
       when kind in [:element, :part] do
    with :ok <- verify_link_semantics(dsl_state, node, path),
         :ok <- verify_node_binding_attr_schema(dsl_state, node, path),
         :ok <-
           verify_resource_view_expression_terms(
             dsl_state,
             resource,
             Map.values(Map.get(node, :attrs, %{})),
             path ++ [:attrs],
             scope
           ),
         :ok <-
           verify_resource_view_expression_terms(
             dsl_state,
             resource,
             Enum.flat_map(events || [], fn
               %EventBinding{} = binding -> Map.values(binding.args_exprs)
               _other -> []
             end),
             path ++ [:events],
             scope
           ),
         :ok <- verify_node_states(dsl_state, nil, node, path),
         :ok <- verify_event_bindings(dsl_state, resource, events, path, node),
         :ok <- verify_node_client_driver_contracts(dsl_state, node, path),
         :ok <- verify_node_client_actions(dsl_state, resource, node, path) do
      Helpers.verify_each(Enum.with_index(children), fn {child, index} ->
        verify_view_node(dsl_state, resource, child, path ++ [kind, index], scope)
      end)
    end
  end

  defp verify_view_node(
         dsl_state,
         resource,
         %{kind: :when, condition: condition, child: child},
         path,
         scope
       ) do
    with :ok <-
           verify_resource_view_expression_terms(
             dsl_state,
             resource,
             [condition],
             path ++ [:when, :condition],
             scope
           ) do
      verify_view_node(dsl_state, resource, child, path ++ [:when], scope)
    end
  end

  defp verify_view_node(
         dsl_state,
         resource,
         %{kind: :if, then: then_child} = node,
         path,
         scope
       ) do
    with :ok <-
           verify_resource_view_expression_terms(
             dsl_state,
             resource,
             [Map.get(node, :condition)],
             path ++ [:if, :condition],
             scope
           ),
         :ok <- verify_view_node(dsl_state, resource, then_child, path ++ [:if, :then], scope) do
      case Map.get(node, :else) do
        nil ->
          :ok

        else_child ->
          verify_view_node(dsl_state, resource, else_child, path ++ [:if, :else], scope)
      end
    end
  end

  defp verify_view_node(
         dsl_state,
         resource,
         %{kind: :each, items: items, child: child, as: as, index: index_alias},
         path,
         scope
       ) do
    child_scope =
      scope
      |> put_template_scope_item(as)
      |> put_template_scope_index(index_alias || as)

    with :ok <-
           verify_resource_view_expression_terms(
             dsl_state,
             resource,
             [items],
             path ++ [:each, :items],
             scope
           ) do
      verify_view_node(dsl_state, resource, child, path ++ [:each], child_scope)
    end
  end

  defp verify_view_node(
         dsl_state,
         resource,
         %{kind: :attached_view, child: child} = node,
         path,
         scope
       ) do
    template = inline_view_template(child)

    with :ok <- verify_view_node(dsl_state, resource, child, path ++ [:child], scope),
         :ok <-
           verify_template_client_actions(
             dsl_state,
             resource,
             template,
             Map.get(node, :client, []),
             path ++ [:client]
           ),
         :ok <-
           verify_template_client_runtimes(
             dsl_state,
             template,
             Map.get(node, :runtimes, []),
             path ++ [:runtimes]
           ) do
      :ok
    end
  end

  defp verify_view_node(
         dsl_state,
         resource,
         %{kind: :resource_component, resource: component_module, assigns: assigns} = node,
         path,
         scope
       ) do
    with {:ok, component_resource} <-
           load_resource_component(dsl_state, component_module, path),
         template <- resource_component_template(component_resource),
         :ok <-
           verify_store_child_relationship(dsl_state, component_module, path, scope),
         :ok <- verify_component_input(dsl_state, resource, template, node, assigns, path, scope),
         :ok <-
           verify_view_node(
             dsl_state,
             component_resource,
             component_resource.view,
             path ++ [:resource_component, :view],
             resource_template_scope(component_resource)
             |> put_resource_component_caller_resource(resource)
             |> inherit_store_owner(scope, component_module)
           ) do
      :ok
    end
  end

  defp verify_view_node(
         dsl_state,
         resource,
         %{kind: :text, content: content},
         path,
         scope
       ) do
    verify_resource_view_expression_terms(dsl_state, resource, [content], path ++ [:text], scope)
  end

  defp verify_view_node(_dsl_state, _resource, nil, _path, _scope), do: :ok
  defp verify_view_node(_dsl_state, _resource, _node, _path, _scope), do: :ok

  defp verify_store_child_relationship(dsl_state, component_module, path, scope) do
    if Ash.Resource.Info.embedded?(component_module) do
      :ok
    else
      owner = Map.get(scope, :store_owner_resource)

      if is_nil(owner) or
           (is_atom(owner) and
              Enum.any?(
                Ash.Resource.Info.relationships(owner),
                &(&1.destination == component_module)
              )) do
        :ok
      else
        {:error,
         Helpers.dsl_error(
           dsl_state,
           path,
           "store-backed render(#{inspect(component_module)}, ...) requires an ordinary " <>
             "relationship from the owning entity resource; that relationship is the read " <>
             "and notification subscription"
         )}
      end
    end
  end

  defp verify_component_input(
         dsl_state,
         resource,
         _template,
         %{record: record},
         _assigns,
         path,
         scope
       ) do
    verify_resource_view_expression_terms(dsl_state, resource, [record], path ++ [:record], scope)
  end

  defp verify_component_input(dsl_state, resource, template, _node, assigns, path, scope) do
    verify_view_template_assigns(dsl_state, resource, template, assigns, path, scope)
  end

  defp load_resource_component(dsl_state, component_module, path)
       when is_atom(component_module) do
    Code.ensure_compiled!(component_module)
    {:ok, AshUi.Compiled.resource!(component_module)}
  rescue
    error in [ArgumentError, Spark.Error.DslError] ->
      _ = error

      {:error,
       Helpers.dsl_error(
         dsl_state,
         path,
         "`render #{inspect(component_module)}` must reference an AshUi value-resource module"
       )}
  end

  defp resource_component_template(component_resource) do
    %{
      name: component_resource.module,
      params: resource_component_params(component_resource.module),
      part_states: %{},
      view: component_resource.view
    }
  end

  defp resource_component_params(component_module) do
    component_module
    |> Ash.Resource.Info.attributes()
    |> Enum.reject(&(&1.name == :session_id))
    |> Enum.map(fn attr ->
      required? = Map.get(attr, :allow_nil?, true) == false and is_nil(Map.get(attr, :default))

      %{
        name: attr.name,
        type: attr.type,
        required?: required?,
        has_default?: not required?
      }
    end)
  end

  defp verify_event_bindings(dsl_state, resource, events, path, node) do
    Helpers.verify_each(events, fn
      %EventBinding{} = binding ->
        with :ok <- verify_event_payload_schema(dsl_state, binding, path),
             :ok <- verify_binding_option_schema(dsl_state, binding, path) do
          verify_event_binding_action_contract(
            dsl_state,
            resource,
            binding,
            path,
            form_field_names(node)
          )
        end

      _other ->
        :ok
    end)
  end

  # A binding names an action on the resource whose view declares it — no
  # caller fallback, no standalone emitters (nested_ui_model.md).
  defp verify_event_binding_action_contract(
         dsl_state,
         declaring_resource,
         binding,
         path,
         form_fields
       ) do
    with :ok <-
           verify_action_target(
             dsl_state,
             declaring_resource,
             binding.ui_event,
             path
           ),
         :ok <-
           verify_event_binding_required_arguments(
             dsl_state,
             declaring_resource,
             binding,
             path,
             form_fields
           ),
         :ok <-
           verify_event_binding_known_arguments(
             dsl_state,
             declaring_resource,
             binding,
             path
           ) do
      :ok
    end
  end

  defp verify_event_payload_schema(dsl_state, %EventBinding{} = binding, path) do
    verify_dom_event_payload_schema(dsl_state, binding, path)
  end

  defp verify_dom_event_payload_schema(dsl_state, %EventBinding{} = binding, path) do
    binding.args_exprs
    |> EventBinding.payload_fields()
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn field, :ok ->
      if EventBinding.payload_field?(binding.dom_event, field) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          Helpers.dsl_error(
            dsl_state,
            path,
            "event(#{inspect(field)}) is not available for #{inspect(binding.dom_event)} events; expected one of #{inspect(EventBinding.payload_schema(binding.dom_event))}"
          )}}
      end
    end)
  end

  defp verify_binding_option_schema(dsl_state, %EventBinding{meta: meta}, path)
       when is_map(meta) do
    Helpers.verify_each([:prevent_default, :stop_propagation], fn key ->
      case Map.fetch(meta, key) do
        {:ok, value} when is_boolean(value) ->
          :ok

        {:ok, value} ->
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path,
             "binding option `#{key}:` expects a boolean, got: #{inspect(value)}"
           )}

        :error ->
          :ok
      end
    end)
  end

  defp verify_binding_option_schema(_dsl_state, _binding, _path), do: :ok

  @standard_part_states MapSet.new([:selected, :open, :disabled])

  defp verify_node_states(dsl_state, template, node, path) do
    part =
      Map.get(node, :part) || get_in(node, [:meta, :part]) ||
        get_in(node, [:meta, :component_part])

    allowed = allowed_part_states(template, part)

    node
    |> Map.get(:states, [])
    |> Helpers.verify_each(fn
      %{name: state} when is_atom(state) ->
        if MapSet.member?(allowed, state) do
          :ok
        else
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path ++ [:state, state],
             "unknown state #{inspect(state)} for part #{inspect(part)}; expected one of #{inspect(MapSet.to_list(allowed))}"
           )}
        end

      _state ->
        :ok
    end)
  end

  defp allowed_part_states(nil, _part), do: @standard_part_states

  defp allowed_part_states(template, part) do
    custom =
      template
      |> Map.get(:part_states, %{})
      |> Map.get(part, [])
      |> Enum.map(& &1.name)

    MapSet.union(@standard_part_states, MapSet.new(custom))
  end

  defp verify_template_client_actions(_dsl_state, _resource, _template, [], _path), do: :ok

  defp verify_template_client_actions(dsl_state, resource, template, client_actions, path) do
    Helpers.verify_each(Enum.with_index(client_actions), fn {action, index} ->
      action_path = path ++ [index]

      with :ok <- verify_template_client_target(dsl_state, template, action, action_path),
           :ok <- verify_action_target(dsl_state, resource, action.action, action_path),
           :ok <- verify_client_dom_event_inference(dsl_state, template, action, action_path) do
        :ok
      end
    end)
  end

  defp verify_template_client_runtimes(_dsl_state, _template, [], _path), do: :ok

  defp verify_template_client_runtimes(dsl_state, template, client_runtimes, path) do
    Helpers.verify_each(Enum.with_index(client_runtimes), fn {runtime, index} ->
      verify_template_client_runtime_target(dsl_state, template, runtime, path ++ [index])
    end)
  end

  defp verify_link_semantics(_dsl_state, _node, _path), do: :ok

  defp literal_attr_value(%Compiled{ir: ir}), do: literal_attr_value(ir)
  defp literal_attr_value(value), do: value

  defp verify_node_binding_attr_schema(dsl_state, %{attrs: attrs}, path) when is_map(attrs) do
    Helpers.verify_each(
      [{"data-ash-ui-debounce", :debounce}, {"data-ash-ui-throttle", :throttle}],
      fn {attr, option} ->
        case Map.fetch(attrs, attr) do
          {:ok, value} ->
            if non_negative_integer_literal?(literal_attr_value(value)) do
              :ok
            else
              {:error,
               Helpers.dsl_error(
                 dsl_state,
                 path,
                 "binding option `#{option}:` expects a non-negative integer millisecond value, got: #{inspect(literal_attr_value(value))}"
               )}
            end

          :error ->
            :ok
        end
      end
    )
  end

  defp verify_node_binding_attr_schema(_dsl_state, _node, _path), do: :ok

  defp non_negative_integer_literal?(value) when is_integer(value), do: value >= 0

  defp non_negative_integer_literal?(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer >= 0
      _other -> false
    end
  end

  defp non_negative_integer_literal?(_value), do: false

  defp component_part?(template, name) do
    Enum.any?(template.parts, &(&1.name == name))
  end

  defp verify_template_client_target(dsl_state, template, %{target: target}, path) do
    if component_part?(template, target) do
      :ok
    else
      {:error,
       Helpers.dsl_error(
         dsl_state,
         path,
         "`client action` references unknown component part #{inspect(target)}"
       )}
    end
  end

  defp verify_client_dom_event_inference(
         dsl_state,
         template,
         %{using: nil, dom_event: nil, target: target},
         path
       ) do
    tag =
      template.parts
      |> Enum.find(&(&1.name == target))
      |> case do
        nil -> nil
        part -> part.tag
      end

    if is_nil(EventBinding.infer_dom_event(tag)) do
      {:error,
       Helpers.dsl_error(
         dsl_state,
         path,
         "`client action` on #{inspect(target)} must declare `using:` or target a click/input/submit-capable part"
       )}
    else
      :ok
    end
  end

  defp verify_client_dom_event_inference(_dsl_state, _template, action, _path) do
    if EventBinding.client_action?(action), do: :ok, else: :ok
  end

  defp verify_node_client_actions(dsl_state, resource, %{meta: meta}, path) when is_map(meta) do
    Helpers.verify_each(Enum.with_index(List.wrap(Map.get(meta, :client_actions, []))), fn
      {action, index} ->
        if EventBinding.client_action?(action) do
          verify_action_target(
            dsl_state,
            resource,
            action.action,
            path ++ [:client_driver, index]
          )
        else
          :ok
        end
    end)
  end

  defp verify_node_client_actions(_dsl_state, _resource, _node, _path), do: :ok

  @client_payload_sources MapSet.new([:textarea_value, :client_read_files])

  defp verify_node_client_driver_contracts(dsl_state, %{attrs: attrs, meta: meta}, path)
       when is_map(meta) do
    Helpers.verify_each(List.wrap(Map.get(meta, :client_driver_contracts, [])), fn driver ->
      with :ok <- verify_island_dom_id(dsl_state, driver, attrs || %{}, path),
           :ok <- verify_client_payload_sources(dsl_state, driver, path) do
        :ok
      end
    end)
  end

  defp verify_node_client_driver_contracts(_dsl_state, _node, _path), do: :ok

  defp verify_island_dom_id(dsl_state, driver, attrs, path) do
    if island_owned_fields(driver) != [] and not stable_dom_id?(attrs) do
      {:error,
       Helpers.dsl_error(
         dsl_state,
         path ++ [:client_driver, driver_name(driver)],
         "client_driver #{inspect(driver_name(driver))} owns fields and requires a stable `dom_id:`; island-owned fields forfeit host input locking and must restore themselves client-side"
       )}
    else
      :ok
    end
  end

  defp verify_client_payload_sources(dsl_state, driver, path) do
    sources =
      driver
      |> Keyword.get(:payload_sources, [])
      |> List.wrap()

    Helpers.verify_each(sources, fn source ->
      normalized = normalize_client_payload_source(source)

      if MapSet.member?(@client_payload_sources, normalized) do
        :ok
      else
        {:error,
         Helpers.dsl_error(
           dsl_state,
           path ++ [:client_driver, driver_name(driver), :payload_sources],
           "unknown client payload source #{inspect(source)}; expected one of #{inspect(MapSet.to_list(@client_payload_sources))}"
         )}
      end
    end)
  end

  defp island_owned_fields(driver) do
    owns = Keyword.get(driver, :owns, Keyword.get(driver, :owned_fields, []))

    cond do
      is_list(owns) -> owns
      is_map(owns) -> Map.get(owns, :fields, Map.get(owns, "fields", []))
      true -> []
    end
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp stable_dom_id?(attrs) when is_map(attrs) do
    case Map.get(attrs, "id", Map.get(attrs, :id)) do
      value when value in [nil, ""] -> false
      _value -> true
    end
  end

  defp driver_name(driver), do: Keyword.get(driver, :name, :unknown)

  defp normalize_client_payload_source(source) when is_atom(source), do: source

  defp normalize_client_payload_source(source) when is_binary(source) do
    source
    |> String.replace("-", "_")
    |> String.to_existing_atom()
  rescue
    ArgumentError -> source
  end

  defp verify_template_client_runtime_target(
         dsl_state,
         template,
         %{target: target},
         path
       ) do
    if component_part?(template, target) do
      :ok
    else
      {:error,
       Helpers.dsl_error(
         dsl_state,
         path,
         "`client runtime` references unknown component part #{inspect(target)}"
       )}
    end
  end

  defp find_action(%{actions: actions}, action_name) do
    Enum.find(actions, &(to_string(&1.name) == to_string(action_name)))
  end

  defp verify_action_target(dsl_state, target_resource, action_name, path) do
    if is_nil(target_resource) do
      :ok
    else
      case find_action(target_resource, action_name) do
        %{type: :create} ->
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path,
             "event binding targets create action `#{inspect(action_name)}`; events require an instance action"
           )}

        %{} ->
          :ok

        nil ->
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path,
             "event binding targets unknown action `#{inspect(action_name)}` on #{inspect(target_resource.module || target_resource.name)}"
           )}
      end
    end
  end

  defp verify_event_binding_required_arguments(_dsl_state, nil, _binding, _path, _form_fields),
    do: :ok

  defp verify_event_binding_required_arguments(
         _dsl_state,
         _target_resource,
         %EventBinding{meta: %{provides_action_payload?: true}},
         _path,
         _form_fields
       ),
       do: :ok

  defp verify_event_binding_required_arguments(
         dsl_state,
         target_resource,
         binding,
         path,
         form_fields
       ) do
    case find_action(target_resource, binding.ui_event) do
      nil ->
        :ok

      action ->
        provided =
          binding.args_exprs
          |> Map.keys()
          |> MapSet.new()
          |> maybe_put_value(binding)
          |> maybe_put_bound_field(binding)
          |> maybe_put_form(binding)
          |> maybe_put_form_fields(binding, form_fields)

        required =
          action.arguments
          |> Enum.filter(&(Map.get(&1, :allow_nil?, true) == false))
          |> Enum.map(& &1.name)

        missing = Enum.reject(required, &MapSet.member?(provided, &1))

        if missing == [] do
          :ok
        else
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path,
             "event binding for #{inspect(binding.ui_event)} is missing required action args #{inspect(missing)}"
           )}
        end
    end
  end

  defp verify_event_binding_known_arguments(_dsl_state, nil, _binding, _path), do: :ok

  defp verify_event_binding_known_arguments(dsl_state, target_resource, binding, path) do
    case find_action(target_resource, binding.ui_event) do
      nil ->
        :ok

      action ->
        known =
          action.arguments
          |> Enum.map(& &1.name)
          |> MapSet.new(&to_string/1)

        extra =
          binding.args_exprs
          |> Map.keys()
          |> Enum.reject(&(to_string(&1) in known))

        if extra == [] do
          :ok
        else
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path,
             "event binding for #{inspect(binding.ui_event)} references unknown action args #{inspect(extra)}"
           )}
        end
    end
  end

  defp maybe_put_value(provided, %EventBinding{meta: %{provides_value?: true}}) do
    MapSet.put(provided, :value)
  end

  defp maybe_put_value(provided, _binding), do: provided

  defp maybe_put_bound_field(provided, %EventBinding{meta: %{bound_field: field}}),
    do: MapSet.put(provided, field)

  defp maybe_put_bound_field(provided, _binding), do: provided

  defp maybe_put_form(provided, %EventBinding{meta: %{provides_form?: true}}) do
    MapSet.put(provided, :form)
  end

  defp maybe_put_form(provided, _binding), do: provided

  defp maybe_put_form_fields(provided, %EventBinding{meta: %{auto_bind: true}}, fields),
    do: MapSet.union(provided, MapSet.new(fields))

  defp maybe_put_form_fields(provided, _binding, _fields), do: provided

  defp form_field_names(%{kind: :element, attrs: attrs, children: children}) do
    field = Map.get(attrs, "name") || Map.get(attrs, :name)

    List.wrap(if(is_atom(field), do: field, else: existing_atom(field))) ++
      form_field_names(children)
  end

  defp form_field_names(%{kind: :resource_component, assigns: assigns}) do
    assigns |> Map.values() |> form_field_names()
  end

  defp form_field_names(%{kind: :if, then: then_node} = node),
    do: form_field_names([then_node, Map.get(node, :else)])

  defp form_field_names(%{kind: kind} = node) when kind in [:fragment, :each, :when],
    do: form_field_names(Map.get(node, :children) || Map.get(node, :child))

  defp form_field_names(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &form_field_names/1)
  defp form_field_names(_node), do: []

  defp existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom(_value), do: nil

  defp verify_view_template_assigns(dsl_state, resource, template, assigns, path, scope) do
    with :ok <- verify_template_assign_contract(dsl_state, template, assigns, path) do
      Helpers.verify_each(assigns, fn {param_name, value} ->
        assign_path = path ++ [:assigns, param_name]

        cond do
          fragment_value?(value) ->
            verify_view_node(dsl_state, resource, value, assign_path, scope)

          true ->
            verify_resource_expression_terms(
              dsl_state,
              resource,
              value,
              assign_path,
              scope,
              template
            )
        end
      end)
    end
  end

  defp verify_template_assign_contract(dsl_state, template, assigns, path) do
    allowed = MapSet.new(Enum.map(template.params, & &1.name))
    provided = MapSet.new(Map.keys(assigns))

    missing =
      template.params
      |> Enum.reject(&Map.get(&1, :has_default?, false))
      |> Enum.map(& &1.name)
      |> Enum.reject(&param_provided?(provided, &1))

    extras =
      provided
      |> MapSet.difference(allowed)
      |> MapSet.to_list()
      |> Enum.sort()

    cond do
      missing != [] ->
        {:error,
         Helpers.dsl_error(
           dsl_state,
           path,
           "`render #{inspect(template.name)}` is missing required params #{inspect(missing)}"
         )}

      extras != [] ->
        {:error,
         Helpers.dsl_error(
           dsl_state,
           path,
           "`render #{inspect(template.name)}` binds unknown params #{inspect(extras)}"
         )}

      true ->
        :ok
    end
  end

  defp verify_resource_view_expression_terms(_dsl_state, _resource, [], _path, _scope), do: :ok

  defp verify_resource_view_expression_terms(dsl_state, resource, terms, path, scope) do
    Helpers.verify_each(List.wrap(terms), fn term ->
      verify_resource_expression_terms(
        dsl_state,
        resource,
        term,
        path,
        scope,
        resource_view_template(resource)
      )
    end)
  end

  defp resource_view_template(resource) do
    %{name: Map.get(resource, :name, :view)}
  end

  defp param_provided?(provided, name) when is_atom(name) do
    MapSet.member?(provided, name) or MapSet.member?(provided, Atom.to_string(name))
  end

  defp param_provided?(provided, name), do: MapSet.member?(provided, name)

  defp verify_resource_expression_terms(_dsl_state, _resource, nil, _path, _scope, _template),
    do: :ok

  defp verify_resource_expression_terms(dsl_state, resource, term, path, scope, template) do
    Helpers.verify_each(collect_resource_refs(term, scope), fn
      {:state, name} ->
        if resource_state?(resource, name) do
          :ok
        else
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path,
             "`render #{inspect(template.name)}` references unknown state #{inspect(name)}"
           )}
        end

      {:route_param, name} ->
        if resource_route_param?(resource, name) do
          :ok
        else
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path,
             "`render #{inspect(template.name)}` references unknown route param #{inspect(name)}"
           )}
        end

      {:item, name} ->
        if template_scope_item?(scope, name) do
          :ok
        else
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path,
             "`render #{inspect(template.name)}` references unknown item binding #{inspect(name)}"
           )}
        end

      {:index, name} ->
        if template_scope_index?(scope, name) do
          :ok
        else
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path,
             "`render #{inspect(template.name)}` references unknown index binding #{inspect(name)}"
           )}
        end

      {:part_id, _name} ->
        :ok

      {:arg, name} ->
        if template_scope_local?(scope, name) do
          :ok
        else
          {:error,
           Helpers.dsl_error(
             dsl_state,
             path,
             "`render #{inspect(template.name)}` references unknown local binding #{inspect(name)}"
           )}
        end

      {:template_only, helper, name} ->
        {:error,
         Helpers.dsl_error(
           dsl_state,
           path,
           "`render #{inspect(template.name)}` cannot use #{helper}(#{inspect(name)}) in resource-view scope"
         )}
    end)
  end

  defp resource_state?(resource, name) do
    Enum.any?(resource.attributes, &(&1.name == name)) or
      Enum.any?(resource.calculations, &(&1.name == name)) or
      Enum.any?(Map.get(resource, :aggregates) || [], &(&1.name == name)) or
      Enum.any?(Map.get(resource, :relationships, []), &(Map.get(&1, :name) == name))
  end

  defp resource_route_param?(resource, name) do
    Enum.any?(Map.get(resource.route, :params, []), &(&1.name == name)) or
      Enum.any?(resource.route.queries, &(&1.name == name)) or
      Enum.any?(resource.route.states, &(&1.param == name))
  end

  defp collect_resource_refs(term, scope) do
    cond do
      match?(%Ref{relationship_path: []}, term) ->
        [{:state, term.attribute}]

      match?(%Ref{relationship_path: [_ | _]}, term) ->
        case term.relationship_path do
          [base | _rest] when is_atom(base) ->
            scoped_dotted_resource_ref(base, scope)

          _other ->
            []
        end

      match?(%Call{name: :state, args: [_]}, term) ->
        [%Call{args: [_name]} = term]
        |> Enum.flat_map(fn %Call{args: [name]} ->
          if is_atom(name) or is_binary(name), do: [{:state, name}], else: []
        end)

      match?(%Call{name: :route_param, args: [_]}, term) ->
        [%Call{args: [_name]} = term]
        |> Enum.flat_map(fn %Call{args: [name]} ->
          if is_atom(name) or is_binary(name), do: [{:route_param, name}], else: []
        end)

      match?(%Call{name: :command_result, args: [_ | _]}, term) ->
        [%Call{args: [_name | _rest]} = term]
        |> Enum.flat_map(fn %Call{args: [name | _rest]} ->
          if is_atom(name), do: [{:command_alias, name}], else: []
        end)

      match?(%Call{name: :item, args: [_, _]}, term) ->
        [%Call{args: [_name, _field]} = term]
        |> Enum.flat_map(fn %Call{args: [name, _field]} ->
          if is_atom(name), do: [{:item, name}], else: []
        end)

      match?(%Call{name: :index, args: [_]}, term) ->
        [%Call{args: [_name]} = term]
        |> Enum.flat_map(fn %Call{args: [name]} ->
          if is_atom(name), do: [{:index, name}], else: []
        end)

      match?(%Call{name: :arg, args: [_]}, term) ->
        [%Call{args: [_name]} = term]
        |> Enum.flat_map(fn %Call{args: [name]} ->
          if is_atom(name), do: [{:arg, name}], else: []
        end)

      match?(%Call{name: :prop, args: [_]}, term) ->
        [%Call{args: [_name]} = term]
        |> Enum.flat_map(fn %Call{args: [name]} ->
          if is_atom(name), do: [{:template_only, :prop, name}], else: []
        end)

      match?(%Call{name: :dom, args: [_]}, term) ->
        [%Call{args: [_name]} = term]
        |> Enum.flat_map(fn %Call{args: [name]} ->
          if is_atom(name), do: [{:template_only, :dom, name}], else: []
        end)

      match?(%Call{name: :part_id, args: [_]}, term) ->
        [%Call{args: [_name]} = term]
        |> Enum.flat_map(fn %Call{args: [name]} ->
          if is_atom(name), do: [{:part_id, name}], else: []
        end)

      match?({:_ref, [], _}, term) ->
        [{:state, elem(term, 2)}]

      match?({:_ref, [_ | _], _}, term) ->
        case term do
          {:_ref, [base | _rest], _field} when is_atom(base) ->
            scoped_dotted_resource_ref(base, scope)

          _other ->
            []
        end

      match?({:_state_path, _}, term) ->
        path = elem(term, 1)

        path
        |> List.wrap()
        |> case do
          [first | rest] when is_atom(first) ->
            [{:state, first} | Enum.flat_map(rest, &collect_resource_refs(&1, scope))]

          path_terms ->
            Enum.flat_map(path_terms, &collect_resource_refs(&1, scope))
        end

      match?({:_route_param, _}, term) ->
        [{:route_param, elem(term, 1)}]

      match?({:_command_result, _}, term) ->
        [{:command_alias, elem(term, 1)}]

      match?({:_command_result, _, _}, term) ->
        [{:command_alias, elem(term, 1)}]

      match?({:_item, _, _}, term) ->
        [{:item, elem(term, 1)}]

      match?({:_index, _}, term) ->
        [{:index, elem(term, 1)}]

      match?({:_arg, _}, term) ->
        [{:arg, elem(term, 1)}]

      match?({:_prop, _}, term) ->
        [{:template_only, :prop, elem(term, 1)}]

      match?({:_dom, _}, term) ->
        [{:template_only, :dom, elem(term, 1)}]

      match?({:_part_id, _}, term) ->
        [{:part_id, elem(term, 1)}]

      is_map(term) ->
        term
        |> Map.values()
        |> Enum.flat_map(&collect_resource_refs(&1, scope))

      is_list(term) ->
        Enum.flat_map(term, &collect_resource_refs(&1, scope))

      is_tuple(term) ->
        case term do
          {:state, _, [name]} when is_atom(name) ->
            [{:state, name}]

          {:route_param, _, [name]} when is_atom(name) ->
            [{:route_param, name}]

          {:command_result, _, [name]} when is_atom(name) ->
            [{:command_alias, name}]

          {:command_result, _, [name, _path]} when is_atom(name) ->
            [{:command_alias, name}]

          {:item, _, [name, _field]} when is_atom(name) ->
            [{:item, name}]

          {:index, _, [name]} when is_atom(name) ->
            [{:index, name}]

          {:arg, _, [name]} when is_atom(name) ->
            [{:arg, name}]

          {:prop, _, [name]} when is_atom(name) ->
            [{:template_only, :prop, name}]

          {:dom, _, [name]} when is_atom(name) ->
            [{:template_only, :dom, name}]

          {:part_id, _, [name]} when is_atom(name) ->
            [{:part_id, name}]

          other ->
            other
            |> Tuple.to_list()
            |> Enum.flat_map(&collect_resource_refs(&1, scope))
        end

      true ->
        []
    end
  end

  defp scoped_dotted_resource_ref(base, scope) when is_atom(base) do
    cond do
      template_scope_item?(scope, base) ->
        [{:item, base}]

      resource_scope_field?(scope, base) ->
        [{:state, base}]

      template_scope_has_items?(scope) ->
        [{:item, base}]

      true ->
        [{:state, base}]
    end
  end

  defp empty_template_scope do
    %{locals: MapSet.new(), items: MapSet.new(), indexes: MapSet.new()}
  end

  defp resource_template_scope(resource) do
    Map.put(empty_template_scope(), :resource_fields, resource_field_names(resource))
  end

  defp put_store_owner(scope, resource) do
    if is_atom(resource) and Ash.Resource.Info.embedded?(resource) do
      scope
    else
      Map.put(scope, :store_owner_resource, resource)
    end
  end

  defp inherit_store_owner(scope, parent_scope, component_module) do
    if Ash.Resource.Info.embedded?(component_module) do
      case Map.get(parent_scope, :store_owner_resource) do
        nil -> scope
        owner -> Map.put(scope, :store_owner_resource, owner)
      end
    else
      Map.put(scope, :store_owner_resource, component_module)
    end
  end

  defp resource_field_names(resource) do
    [:attributes, :relationships, :calculations]
    |> Enum.flat_map(fn field -> Enum.map(Map.get(resource, field, []), & &1.name) end)
    |> MapSet.new()
  end

  defp resource_scope_field?(scope, field) do
    MapSet.member?(Map.get(scope, :resource_fields, MapSet.new()), field)
  end

  defp put_resource_component_caller_resource(scope, resource) do
    Map.put(scope, :resource_component_caller_resource, resource)
  end

  defp put_template_scope_item(scope, name) when is_atom(name) do
    scope
    |> update_in([:locals], &MapSet.put(&1, name))
    |> update_in([:items], &MapSet.put(&1, name))
  end

  defp put_template_scope_index(scope, name) when is_atom(name) do
    update_in(scope, [:indexes], &MapSet.put(&1, name))
  end

  defp template_scope_local?(scope, name),
    do: MapSet.member?(Map.get(scope, :locals, MapSet.new()), name)

  defp template_scope_item?(scope, name),
    do: MapSet.member?(Map.get(scope, :items, MapSet.new()), name)

  defp template_scope_index?(scope, name),
    do: MapSet.member?(Map.get(scope, :indexes, MapSet.new()), name)

  defp template_scope_has_items?(scope),
    do: MapSet.size(Map.get(scope, :items, MapSet.new())) > 0

  defp fragment_value?(%{kind: kind})
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
            ],
       do: true

  defp fragment_value?(_value), do: false

  defp inline_view_template(child) do
    %{
      name: :__inline_view__,
      params: [],
      parts: collect_inline_view_parts(child)
    }
  end

  defp collect_inline_view_parts(%{kind: :element, part: name, children: children})
       when is_atom(name) do
    [%{name: name, attrs: %{}}] ++
      Enum.flat_map(children, &collect_inline_view_parts/1)
  end

  defp collect_inline_view_parts(%{kind: :element, children: children}),
    do: Enum.flat_map(children, &collect_inline_view_parts/1)

  defp collect_inline_view_parts(%{kind: :fragment, children: children}),
    do: Enum.flat_map(children, &collect_inline_view_parts/1)

  defp collect_inline_view_parts(%{kind: :stack, children: children}),
    do: Enum.flat_map(children, &collect_inline_view_parts/1)

  defp collect_inline_view_parts(%{kind: :row, children: children}),
    do: Enum.flat_map(children, &collect_inline_view_parts/1)

  defp collect_inline_view_parts(%{kind: :when, child: child}),
    do: collect_inline_view_parts(child)

  defp collect_inline_view_parts(%{kind: :if, then: then_child} = node) do
    collect_inline_view_parts(then_child) ++
      case Map.get(node, :else) do
        nil -> []
        else_child -> collect_inline_view_parts(else_child)
      end
  end

  defp collect_inline_view_parts(%{kind: :each, child: child}),
    do: collect_inline_view_parts(child)

  defp collect_inline_view_parts(_other), do: []
end
