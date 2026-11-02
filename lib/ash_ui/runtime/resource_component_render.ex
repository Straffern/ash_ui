defmodule AshUi.Runtime.ResourceComponentRender do
  @moduledoc false

  alias AshUi.Runtime.ViewRender

  def render(caller_resource, node, caller_record, caller_params, opts) when is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    render(caller_resource, node, caller_record, caller_params, opts)
  end

  def render(
        _caller_resource,
        %{kind: :resource_component, resource: component_module, assigns: assigns} = node,
        caller_record,
        caller_params,
        opts
      ) do
    opts = push_parent_record(opts, caller_record)

    with {:ok, component_params} <-
           evaluate_component_input(node, assigns, caller_record, caller_params, opts) do
      case build_resource_component_record(component_module, component_params, opts) do
        {:error, error} ->
          first = error |> AshUi.Runtime.Errors.list() |> List.first()

          boundary_message =
            case AshUi.Runtime.Errors.field(first) do
              nil -> AshUi.Runtime.Errors.message(first)
              field -> "#{field}: #{AshUi.Runtime.Errors.message(first)}"
            end

          # invalid child input degrades AT THE BOUNDARY, identically in
          # the differential renderer: the page survives and the ORIGINAL
          # Ash error projects through the standard error surface. Real
          # render failures inside a valid child still propagate.
          {:ok,
           %AshUi.RenderTree.Element{
             tag: "div",
             attrs: %{
               "data-ash-ui-error" => "invalid-child-input",
               "role" => "alert"
             },
             children: [
               %AshUi.RenderTree.Text{content: boundary_message}
             ]
           }}

        {:ok, component_record} ->
          component_resource = AshUi.Compiled.resource!(component_module)

          with {:ok, evaluated_client_actions} <-
                 ViewRender.evaluate_client_actions(
                   Map.get(node, :client, []),
                   caller_record,
                   caller_params,
                   opts
                 ),
               {:ok, evaluated_client_runtimes} <-
                 ViewRender.evaluate_client_runtimes(
                   Map.get(node, :runtimes, []),
                   caller_record,
                   caller_params,
                   opts
                 ),
               opts <- push_child_chain(opts, node),
               {:ok, rendered_tree} <-
                 render_tree(
                   component_resource,
                   component_record,
                   component_params,
                   opts,
                   evaluated_client_actions,
                   evaluated_client_runtimes,
                   Map.get(node, :__bp_screen_navigation_routes__)
                 ) do
            {:ok, %{kind: :component, component: component_module, view: rendered_tree}}
          end
      end
    end
  end

  defp evaluate_component_input(%{record: record}, _assigns, caller_record, caller_params, opts) do
    ViewRender.evaluate_value(record, caller_record, caller_params, opts)
  end

  defp evaluate_component_input(_node, assigns, caller_record, caller_params, opts) do
    ViewRender.evaluate_assigns(assigns, caller_record, caller_params, opts)
  end

  def build_resource_component_record(resource, input, opts)
      when is_atom(resource) and is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    build_resource_component_record(resource, input, opts)
  end

  def build_resource_component_record(resource, input, opts)
      when is_atom(resource) and is_map(opts) do
    if embedded_resource?(resource) do
      case input do
        %{__struct__: ^resource} = record ->
          {:ok, record}

        input ->
          build_embedded_record(resource, unify_embedded_input(resource, input, opts), opts)
      end
    else
      current = unify_store_input(resource, input, opts)

      case cached_store_record(resource, current, opts) do
        {:ok, cached} ->
          merged = merge_current_record(cached, current)
          put_cached_store_record(resource, merged, opts)
          {:ok, merged}

        :miss ->
          case load_store_view(current, resource, opts) do
            {:ok, loaded} = ok ->
              put_cached_store_record(resource, loaded, opts)
              ok

            {:error, _reason} = error ->
              error
          end
      end
    end
  rescue
    error in [ArgumentError, Ash.Error.Invalid, Ash.Error.Framework] -> {:error, error}
  end

  defp build_embedded_record(resource, input, opts) do
    action = Map.get(opts, :action, :create)

    resource
    |> Ash.Changeset.for_create(action, input, ash_opts(resource, opts))
    |> Ash.Changeset.apply_attributes()
    |> case do
      {:ok, record} ->
        {:ok, record}

      {:error, changeset} ->
        {:error, Ash.Error.to_error_class(changeset.errors, changeset: changeset)}
    end
  end

  defp unify_embedded_input(resource, input, opts) when is_map(input) do
    with [_first_key | _rest] = keys <- Ash.Resource.Info.primary_key(resource),
         true <- input_has_keys?(input, keys),
         %_{} = parent <- Map.get(opts, :parent_record),
         %{__struct__: ^resource} = stored <- find_stored_embedded(parent, resource, input, keys) do
      overlay_nil_stored_fields(stored, input)
    else
      _other -> input
    end
  end

  defp unify_embedded_input(_resource, input, _opts), do: input

  defp input_has_keys?(input, keys) do
    Enum.all?(keys, &(not is_nil(input_value(input, &1))))
  end

  defp find_stored_embedded(parent, resource, input, keys) do
    parent.__struct__
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(&match?(%{type: {:array, ^resource}}, &1))
    |> Enum.flat_map(&List.wrap(Map.get(parent, &1.name)))
    |> Enum.find(fn stored ->
      Enum.all?(keys, fn key ->
        Map.get(stored, key) == (Map.get(input, key) || Map.get(input, Atom.to_string(key)))
      end)
    end)
  end

  defp overlay_nil_stored_fields(stored, input) do
    stored
    |> Map.from_struct()
    |> Map.take(Enum.map(Ash.Resource.Info.attributes(stored.__struct__), & &1.name))
    |> Map.merge(input, fn _key, stored_value, input_value ->
      if is_nil(stored_value), do: input_value, else: stored_value
    end)
  end

  defp unify_store_input(resource, %_{} = record, _opts) when record.__struct__ == resource,
    do: record

  defp unify_store_input(resource, input, opts) when is_map(input) do
    input = put_parent_session_id(resource, input, opts)

    with [_first | _rest] = keys <- session_identity_keys(resource),
         true <- input_has_keys?(input, keys),
         %{__struct__: ^resource} = stored <-
           find_stored_relationship(opts, resource, input, keys) do
      overlay_input_fields(stored, input)
    else
      _other -> build_store_prototype(resource, input, opts)
    end
  end

  # The caller's input is the projection contract for the fields it names
  # (signed_in?, email, ...); the ROW is truth for its own state
  # (menu_open?, ...). A found row without the overlay silently reverts
  # caller-projected fields to row defaults.
  defp overlay_input_fields(stored, input) do
    stored.__struct__
    |> Ash.Resource.Info.attributes()
    |> Enum.reduce(stored, fn attribute, acc ->
      case fetch_input(input, attribute.name) do
        {:ok, value} -> Map.put(acc, attribute.name, value)
        :error -> acc
      end
    end)
  end

  defp put_parent_session_id(resource, input, opts) do
    if Ash.Resource.Info.attribute(resource, :session_id) &&
         is_nil(Map.get(input, :session_id) || Map.get(input, "session_id")) do
      case parent_session_id(opts) || Map.get(opts, :session_id) do
        session_id when not is_nil(session_id) -> Map.put(input, :session_id, session_id)
        _missing -> input
      end
    else
      input
    end
  end

  defp build_store_prototype(resource, input, opts) do
    action =
      case Ash.Resource.Info.action(resource, :mount, :create) do
        nil -> Ash.Resource.Info.primary_action(resource, :create)
        action -> action
      end

    case action do
      %{name: action_name} ->
        context =
          opts
          |> Map.get(:context, %{})
          |> Map.put(:session_id, Map.get(input, :session_id) || Map.get(input, "session_id"))

        resource
        |> Ash.Changeset.for_create(
          action_name,
          Map.take(input, MapSet.to_list(Ash.Resource.Info.action_inputs(resource, action_name))),
          ash_opts(resource, Map.put(opts, :context, context))
        )
        |> Ash.Changeset.apply_attributes()
        |> case do
          {:ok, record} ->
            record

          {:error, changeset} ->
            raise Ash.Error.to_error_class(changeset.errors, changeset: changeset)
        end

      nil ->
        struct(resource, input)
    end
  end

  defp load_store_view(record, resource, opts) do
    case AshUi.view_load(resource) do
      [] ->
        {:ok, record}

      loads ->
        load_opts =
          if Map.get(opts, :reuse_loaded_values?, false) do
            Keyword.put(ash_opts(resource, opts), :reuse_values?, true)
          else
            ash_opts(resource, opts)
          end

        Ash.load(record, loads, load_opts)
    end
  end

  defp cached_store_record(resource, record, opts) do
    case fetch_cached_child_record(
           resource,
           Map.get(opts, :child_record_cache_boundary),
           opts
         ) do
      {:ok, cached} ->
        {:ok, cached}

      :miss ->
        with {:ok, key} <- child_record_cache_key(resource, record) do
          get_cached_record(key, opts)
        else
          :error -> :miss
        end
    end
  end

  defp put_cached_store_record(resource, record, opts) do
    with {:ok, key} <- child_record_cache_key(resource, record) do
      put_cached_record(key, record, opts)

      case Map.get(opts, :child_record_cache_boundary) do
        nil -> :ok
        boundary -> put_cached_record({:boundary, resource, boundary}, record, opts)
      end
    end

    :ok
  end

  @doc false
  def fetch_cached_child_record(resource, boundary, opts)
      when is_atom(resource) and is_list(opts),
      do: fetch_cached_child_record(resource, boundary, opts |> Enum.reverse() |> Map.new())

  def fetch_cached_child_record(resource, boundary, opts)
      when is_atom(resource) and is_map(opts) do
    if is_nil(boundary) do
      :miss
    else
      get_cached_record({:boundary, resource, boundary}, opts)
    end
  end

  defp get_cached_record(key, opts) do
    case Map.get(opts, :child_record_cache_get) do
      get when is_function(get, 1) -> get.(key)
      _missing -> :miss
    end
  end

  defp put_cached_record(key, record, opts) do
    case Map.get(opts, :child_record_cache_put) do
      put when is_function(put, 2) -> put.(key, record)
      _missing -> :ok
    end
  end

  defp child_record_cache_key(resource, record) do
    keys =
      case session_identity_keys(resource) do
        [] -> Ash.Resource.Info.primary_key(resource)
        keys -> keys
      end

    values = Enum.map(keys, &Map.get(record, &1))

    if keys != [] and Enum.all?(values, &(not is_nil(&1))) do
      {:ok, {resource, List.to_tuple(values)}}
    else
      :error
    end
  end

  # The current parent record owns fresh row attributes and every relationship
  # branch it explicitly loaded. The cache supplies only values that are still
  # NotLoaded on that current row.
  defp merge_current_record(cached, current) do
    Map.merge(cached, current, fn
      _key, cached_value, %Ash.NotLoaded{} -> cached_value
      _key, _cached_value, current_value -> current_value
    end)
  end

  defp ash_opts(resource, opts) do
    [
      actor: Map.get(opts, :actor),
      tenant: Map.get(opts, :tenant),
      context: Map.get(opts, :context, %{}),
      domain: Ash.Resource.Info.domain(resource) || AshUi.AshDomainFallback,
      authorize?: true
    ]
  end

  defp session_identity_keys(resource) do
    resource
    |> Ash.Resource.Info.identities()
    |> Enum.find_value([], fn identity ->
      keys = List.wrap(Map.get(identity, :keys, []))
      if :session_id in keys, do: keys
    end)
  end

  defp find_stored_relationship(opts, resource, input, keys) do
    opts
    |> parent_records()
    |> Enum.flat_map(fn parent ->
      parent.__struct__
      |> Ash.Resource.Info.relationships()
      |> Enum.filter(&(Map.get(&1, :destination) == resource))
      |> Enum.flat_map(fn relationship ->
        case Map.get(parent, relationship.name) do
          %Ash.NotLoaded{} -> []
          value -> List.wrap(value)
        end
      end)
    end)
    |> Enum.find(fn row ->
      Enum.all?(keys, fn key -> Map.get(row, key) == input_value(input, key) end)
    end)
  end

  defp input_value(input, key) do
    case fetch_input(input, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_input(input, key) do
    case Map.fetch(input, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(input, Atom.to_string(key))
    end
  end

  defp push_parent_record(opts, %_{} = record) do
    parent_records = Map.get(opts, :parent_records, [])

    opts
    |> Map.put(:parent_record, record)
    |> Map.put(:parent_records, [record | parent_records])
  end

  defp parent_records(opts) do
    records = Map.get(opts, :parent_records, [])

    case {Map.get(opts, :parent_record), records} do
      {%_{} = parent, [first | _rest]} when first == parent -> records
      {%_{} = parent, records} -> [parent | records]
      {_missing, records} -> records
    end
  end

  defp parent_session_id(opts) do
    Enum.find_value(parent_records(opts), fn
      %{session_id: session_id} when not is_nil(session_id) -> session_id
      _record -> nil
    end)
  end

  defp embedded_resource?(resource) when is_atom(resource) do
    (function_exported?(resource, :spark_is, 0) or
       (Code.ensure_loaded?(resource) and function_exported?(resource, :spark_is, 0))) and
      Ash.Resource.Info.embedded?(resource)
  rescue
    _error in [ArgumentError, UndefinedFunctionError] -> false
  end

  defp render_tree(
         component_resource,
         component_record,
         component_params,
         opts,
         client_actions,
         client_runtimes,
         navigation_routes
       ) do
    module = component_resource.module
    client_actions_by_part = ViewRender.group_client_entities_by_target(client_actions)
    client_runtimes_by_part = ViewRender.group_client_entities_by_target(client_runtimes)

    component_opts =
      opts
      |> Map.drop([
        :current_template,
        :current_template_name,
        :current_component_part_states_by_part
      ])
      |> Map.merge(%{
        ash_resource_module: module,
        helper_module: module,
        client_actions: client_actions,
        client_actions_by_part: client_actions_by_part,
        client_runtimes: client_runtimes,
        client_runtimes_by_part: client_runtimes_by_part
      })
      |> ViewRender.put_expr_scope_base(component_record, component_params)

    # The child's view must be address-stamped like the root's (Rendering
    # stamps only the top-level view): binding keys inside a runtime child
    # are chain + the element's OWN stamped address — never ordinal paths.
    view =
      case navigation_routes do
        %{all: _all, patch: _patch} = routes ->
          AshUi.Patch.Compiler.annotate_screen_navigation(component_resource.view, routes)

        _missing ->
          component_resource.view
      end

    ViewRender.render_view_node(
      component_resource,
      AshUi.Patch.Compiler.stamp_addresses(view),
      component_record,
      component_params,
      component_opts
    )
  end

  # Crossing render(Child, input): the binding chain gains the child slot's
  # stamped address — the same component LiveRender's push_chain and the
  # resolver's child descent use.
  defp push_child_chain(opts, node) do
    opts =
      ViewRender.put_error_scope(opts, ViewRender.expression_path(Map.get(node, :record), opts))

    case Map.get(node, :__bp_addr__) do
      nil ->
        opts

      addr ->
        component = AshUi.Patch.Compiler.addr_component(addr)
        Map.update(opts, :__bp_chain__, [component], &(&1 ++ [component]))
    end
  end
end
