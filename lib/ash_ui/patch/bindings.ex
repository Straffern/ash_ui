defmodule AshUi.Patch.Bindings do
  @moduledoc """
  Registration-free event binding resolution over the compiled patch table.

  A live binding key names WHERE the binding lives, not a session-registered
  value: `child-addr… item-key… element-addr . dom-event` (dot-joined
  components; addresses encode `/`→`-`, `*`→`x`). Resolution walks the key
  against the compiled tables — descending into child tables at child
  addresses, binding items by primary key at each boundaries — then
  re-evaluates the element's event bindings against the CURRENT record.
  The result is the same fully-evaluated `EventBinding` the render-time
  registration used to produce, with payload expressions evaluated at
  dispatch time from live state instead of captured at render.
  """

  alias AshUi.EventBinding
  alias AshUi.Expr.Scope
  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Evaluator
  alias AshUi.Patch.Keys
  alias AshUi.Patch.Table

  @empty_bindings %{
    items: %{},
    indexes: %{},
    paths: %{},
    actor: nil,
    tenant: nil,
    context: %{},
    parents: [],
    session_id: nil
  }

  @doc """
  Resolve a live binding key against `record`'s resource.

  Returns `{:ok, evaluated_binding, target}` or `:error`. The target names
  the INSTANCE the action runs on — dispatch is backing-blind above it:

    * `{:root}` — the page row (bindings declared in the page's own view,
      including inside its eaches).
    * `{:row, child_record}` — a store-backed child instance: the action
      runs on the child's own row.
    * Embedded children reached through `render(Child, input)` are
      addressable only when the input is an instance path (DESIGN.md §4).
      A projected embedded value is traversal-only: its own events resolve
      to `:error`, while an addressable store-backed child nested inside it
      becomes that child's ordinary row target. (Embedded instances
      addressed by parent paths dispatch through
      `AshUi.Patch.Dispatch.embedded_update/5`.)
  """
  @spec resolve(struct(), String.t(), map()) ::
          {:ok, EventBinding.t(),
           {:root}
           | {:row, struct()}
           | {:embedded, struct(), [atom() | {:item, term()}]}}
          | :error
  def resolve(%resource{} = record, binding_key, params \\ %{}, opts \\ [])
      when is_binary(binding_key) and is_list(opts) do
    with [_ | _] = components <- String.split(binding_key, "."),
         {components, [event_component]} <- Enum.split(components, -1) do
      bindings = %{
        @empty_bindings
        | actor: Keyword.get(opts, :actor),
          tenant: Keyword.get(opts, :tenant),
          context: opts |> Keyword.get(:context, %{}) |> Map.new(),
          session_id: Keyword.get(opts, :session_id)
      }

      table =
        case Keyword.get(opts, :table) do
          %Table{resource: ^resource} = table -> table
          _other -> Compiler.table(resource)
        end

      walk(
        table,
        resource,
        record,
        bindings,
        components,
        event_component,
        params,
        {:root}
      )
    else
      _other -> :error
    end
  end

  # ── key walk ───────────────────────────────────────────────────────────────

  defp walk(_table, _resource, _record, _bindings, [], _event, _params, _target), do: :error

  defp walk(
         %Table{} = table,
         resource,
         record,
         item_bindings,
         [component | rest],
         event,
         params,
         target
       ) do
    addr = Compiler.decode_addr_component(component)

    cond do
      # final component: the element itself
      rest == [] and is_map_key(table.event_elements, addr) ->
        entry = Map.fetch!(table.event_elements, addr)

        with {:ok, item_bindings} <-
               bind_items(entry.eaches, [], resource, record, item_bindings, params),
             :ok <- reachable(entry, resource, record, item_bindings, params),
             {:ok, binding} <-
               evaluate(entry.node, resource, record, item_bindings, event, params),
             :ok <- dispatchable_target(target) do
          {:ok, binding, target}
        end

      # child boundary: descend into the child table with the child record
      match?(%Table{}, child_table(table, addr)) ->
        child_table = child_table(table, addr)

        with {:ok, child_record, child_slot} <-
               child_record(
                 table,
                 child_table,
                 addr,
                 resource,
                 record,
                 item_bindings,
                 params
               ),
             {:ok, child_target} <-
               child_dispatch_target(
                 child_table.resource,
                 child_record,
                 child_slot,
                 record,
                 item_bindings,
                 target
               ) do
          walk(
            child_table,
            child_table.resource,
            child_record,
            reset_bindings(item_bindings, record),
            rest,
            event,
            params,
            child_target
          )
        end

      # otherwise: an item key for the FINAL element's each chain — collect
      # keys until the element address appears
      true ->
        collect_keys(
          table,
          resource,
          record,
          item_bindings,
          [component | rest],
          event,
          params,
          target
        )
    end
  end

  defp collect_keys(table, resource, record, item_bindings, components, event, params, target) do
    {keys, rest} =
      Enum.split_while(components, fn component ->
        addr = Compiler.decode_addr_component(component)

        not is_map_key(table.event_elements, addr) and not is_map_key(table.children, addr)
      end)

    case rest do
      [element_component] ->
        addr = Compiler.decode_addr_component(element_component)
        entry = Map.get(table.event_elements, addr)

        with %{} <- entry,
             {:ok, item_bindings} <-
               bind_items(entry.eaches, keys, resource, record, item_bindings, params),
             :ok <- reachable(entry, resource, record, item_bindings, params),
             {:ok, binding} <-
               evaluate(entry.node, resource, record, item_bindings, event, params),
             :ok <- dispatchable_target(target) do
          {:ok, binding, target}
        else
          _other -> :error
        end

      [child_component | remaining] ->
        addr = Compiler.decode_addr_component(child_component)

        with %Table{} = child_table <- child_table(table, addr),
             {:ok, item_bindings} <-
               bind_chain_items(table, addr, keys, resource, record, item_bindings, params),
             {:ok, child_record, child_slot} <-
               child_record(
                 table,
                 child_table,
                 addr,
                 resource,
                 record,
                 item_bindings,
                 params
               ),
             {:ok, child_target} <-
               child_dispatch_target(
                 child_table.resource,
                 child_record,
                 child_slot,
                 record,
                 item_bindings,
                 target
               ) do
          walk(
            child_table,
            child_table.resource,
            child_record,
            reset_bindings(item_bindings, record),
            remaining,
            event,
            params,
            child_target
          )
        else
          _other -> :error
        end

      [] ->
        :error
    end
  end

  # item keys for a child slot's enclosing eaches come from the event walk of
  # the child address — reuse the element entry when one exists, else no eaches
  defp bind_chain_items(table, addr, keys, resource, record, item_bindings, params) do
    case Map.get(table.event_elements, addr) do
      %{eaches: eaches} -> bind_items(eaches, keys, resource, record, item_bindings, params)
      nil when keys == [] -> {:ok, item_bindings}
      nil -> :error
    end
  end

  # ── dispatch target: the storage seam, resolved once per boundary ─────────

  # A store-backed child instance is its own dispatch target (row write). An
  # embedded child reached through render(Child, input) is addressable only
  # via an instance path. Projected inputs are traversal-only so a nested
  # store child can still replace the projection with its own row target.
  defp child_dispatch_target(
         child_resource,
         child_record,
         child_slot,
         record,
         item_bindings,
         target
       ) do
    if Ash.Resource.Info.embedded?(child_resource) do
      case expression_path(Map.get(child_slot.meta, :record), item_bindings) do
        {:ok, relative_path} ->
          with {:ok, parent_record, base_path} <- parent_target(target, record) do
            {:ok, {:embedded, parent_record, base_path ++ relative_path}}
          end

        :error ->
          {:ok, {:projection}}
      end
    else
      {:ok, {:row, child_record}}
    end
  end

  defp parent_target({:root}, record), do: {:ok, record, []}
  defp parent_target({:row, record}, record), do: {:ok, record, []}

  defp parent_target({:embedded, parent_record, path}, _record),
    do: {:ok, parent_record, path}

  defp parent_target(_target, _record), do: :error

  defp dispatchable_target({:projection}), do: :error
  defp dispatchable_target(_target), do: :ok

  # ── reachability: a target in a switched-off branch arm is stale ──────────

  defp reachable(entry, resource, record, item_bindings, params) do
    scope = scope(resource, record, item_bindings, params)

    entry
    |> Map.get(:conditions, [])
    |> Enum.all?(fn
      {:truthy, condition} -> truthy?(Evaluator.eval(condition, scope))
      {:falsy, condition} -> not truthy?(Evaluator.eval(condition, scope))
    end)
    |> case do
      true -> :ok
      false -> :error
    end
  end

  defp truthy?(value), do: value not in [nil, false]

  # ── item binding by primary key ────────────────────────────────────────────

  defp bind_items(eaches, keys, resource, record, bindings, params) do
    if length(eaches) != length(keys) and keys != [] do
      :error
    else
      keys = if keys == [], do: List.duplicate(nil, length(eaches)), else: keys

      eaches
      |> Enum.zip(keys)
      |> Enum.reduce_while({:ok, bindings}, fn {each, key}, {:ok, bindings} ->
        scope = scope(resource, record, bindings, params)
        items = each.items_eval |> Evaluator.eval(scope) |> List.wrap()

        case find_item(items, key, each, resource, record, bindings, params) do
          {:ok, item, ordinal} ->
            bindings = put_in(bindings.items[each.as], item)

            bindings =
              case item_path(each, item, bindings) do
                {:ok, path} -> put_in(bindings.paths[each.as], path)
                :error -> bindings
              end

            bindings =
              if each.index in [nil, each.as],
                do: bindings,
                else: put_in(bindings.indexes[each.index], ordinal)

            {:cont, {:ok, bindings}}

          :error ->
            {:halt, :error}
        end
      end)
    end
  end

  defp find_item(_items, nil, _each, _resource, _record, _bindings, _params), do: :error

  defp find_item(items, key_component, each, resource, record, bindings, params) do
    items
    |> Enum.with_index()
    |> Enum.find_value(:error, fn {item, ordinal} ->
      key_scope =
        scope(resource, record, put_in(bindings.items[each.as], item), params)

      item_key = Keys.entry_key(item, ordinal, Map.get(each, :key_eval), key_scope)

      if EventBinding.key_component(item_key) == key_component do
        {:ok, item, ordinal}
      end
    end)
  end

  defp item_path(each, %resource{} = item, bindings) do
    with {:ok, collection_path} <- expression_path(Map.get(each, :items_ir), bindings),
         [_first | _rest] = fields <- Ash.Resource.Info.primary_key(resource) do
      key =
        case fields do
          [field] -> Map.get(item, field)
          fields -> fields |> Enum.map(&Map.get(item, &1)) |> List.to_tuple()
        end

      if is_nil(key), do: :error, else: {:ok, collection_path ++ [{:item, key}]}
    else
      _other -> :error
    end
  end

  defp item_path(_each, _item, _bindings), do: :error

  defp expression_path(%AshUi.Expr.Compiled{ir: ir}, bindings),
    do: expression_path(ir, bindings)

  defp expression_path({:_ref, path, field}, _bindings)
       when is_list(path) and is_atom(field),
       do: {:ok, path ++ [field]}

  defp expression_path({:_item, binding, path}, bindings)
       when is_atom(binding) and is_list(path) do
    case Map.get(bindings.paths, binding) do
      [_first | _rest] = base -> {:ok, base ++ path}
      _other -> :error
    end
  end

  defp expression_path(_expression, _bindings), do: :error

  # ── evaluation: the same pipeline render-time registration used ───────────

  defp evaluate(element, resource, record, bindings, event_component, params) do
    compiled = AshUi.Runtime.ResourceInfo.compiled_resource(resource)

    with {:ok, rendered} <-
           AshUi.Runtime.Rendering.render_view(
             %{compiled | view: Map.put(element, :children, [])},
             record,
             params,
             item_bindings: bindings.items,
             index_bindings: bindings.indexes,
             actor: bindings.actor,
             tenant: bindings.tenant,
             context: bindings.context
           ),
         %EventBinding{} = binding <-
           rendered
           |> Map.get(:events, [])
           |> List.wrap()
           |> Enum.find(:error, fn %EventBinding{} = binding ->
             EventBinding.event_key_component(binding.dom_event) == event_component
           end) do
      {:ok, binding}
    else
      _other -> :error
    end
  end

  defp child_record(table, child_table, addr, resource, record, item_bindings, params) do
    # The child slot may live inside keyed item_slots (child-in-each) —
    # the finder descends; the scope carries the bound items so the child
    # input evaluates with the right row in scope.
    case Compiler.child_slot(table, addr) do
      nil ->
        :error

      slot ->
        input = Evaluator.eval(slot.eval, scope(resource, record, item_bindings, params))
        child = child_table.resource

        case AshUi.Runtime.ResourceComponentRender.build_resource_component_record(
               child,
               input,
               parent_record: record,
               parent_records: [record | item_bindings.parents],
               actor: item_bindings.actor,
               tenant: item_bindings.tenant,
               context: item_bindings.context,
               session_id: item_bindings.session_id
             ) do
          {:ok, child_record} -> {:ok, child_record, slot}
          {:error, _reason} -> :error
        end
    end
  end

  defp child_table(%Table{} = table, addr) do
    Map.get(table.children, addr) ||
      case Compiler.child_slot(table, addr) do
        %{meta: %{resource: resource}} when is_atom(resource) ->
          Compiler.table(resource, target: table.target)

        _missing ->
          nil
      end
  end

  defp scope(resource, record, bindings, params) do
    Scope.new(record, params,
      ash_resource_module: resource,
      item_bindings: bindings.items,
      index_bindings: bindings.indexes,
      actor: bindings.actor,
      tenant: bindings.tenant,
      context: bindings.context
    )
  end

  defp reset_bindings(bindings, parent) do
    %{
      @empty_bindings
      | actor: bindings.actor,
        tenant: bindings.tenant,
        context: bindings.context,
        parents: [parent | bindings.parents],
        session_id: bindings.session_id
    }
  end
end
