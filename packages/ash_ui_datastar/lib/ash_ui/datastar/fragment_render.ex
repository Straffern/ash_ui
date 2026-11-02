defmodule AshUi.Datastar.FragmentRender do
  @moduledoc """
  Projects the neutral `AshUi.Rendered` algebra through the core
  `AshUi.Diff` kernel into Datastar updates.

  The core kernel owns fingerprints, dynamic invalidation, duplicate-key
  checks, and keyed entry changes. This adapter renders the corresponding
  Datastar-target element and encodes only the selector-scoped SSE operation
  required to apply that result.
  """

  alias AshUi.Datastar.{RenderTarget, SSE}
  alias AshUi.Expr.Scope
  alias AshUi.Patch.{Compiler, Evaluator, Keys, Runtime, Table}
  alias AshUi.RenderTree.{Element, Fragment, Portal}
  alias AshUi.Runtime.ResourceComponentRender
  alias AshUi.{Comprehension, Diff, Rendered}
  alias AshUi.Rendered.Materialize

  @bulk_keyed_threshold 32

  @spec initial_render(struct(), Table.t(), keyword()) :: {binary(), map()}
  def initial_render(%_{} = record, %Table{} = table, opts \\ []) do
    ensure_target!(table)

    measure_mount_layer(:initial_render_materialize, fn ->
      # same target, same compiled artifact: the supplied table IS the
      # differential table — nothing recompiles
      live_table = Keyword.get(opts, :live_table, table)

      {{materialized_html, live_state}, child_records} =
        with_child_record_cache(%{}, fn cache_opts ->
          opts = Keyword.merge(opts, cache_opts)

          # memoized: the diff and the keyed snapshot walk ONE evaluation of
          # the dynamics instead of re-evaluating the whole tree each
          rendered =
            measure_mount_layer(:initial_render_eval, fn ->
              live_render(record, :all, live_table, Keyword.put(opts, :eager?, true))
            end)

          {diff, prints} =
            measure_mount_layer(:initial_diff, fn ->
              live_diff(rendered, Diff.new_fingerprints())
            end)

          materialized_html =
            measure_mount_layer(:initial_materialize, fn ->
              rendered
              |> Materialize.to_iodata()
              |> IO.iodata_to_binary()
              |> prefix_bridge_urls(Keyword.get(opts, :base_path, ""))
            end)

          wire_diff = prefix_diff_urls(diff, Keyword.get(opts, :base_path, ""))

          {keyed, keyed_attrs} =
            measure_mount_layer(:initial_keyed_snapshot, fn ->
              keyed_snapshot(rendered, live_table)
            end)

          {materialized_html,
           %{
             prints: prints,
             diff: wire_diff,
             keyed: keyed,
             keyed_attrs: keyed_attrs,
             table: live_table
           }}
        end)

      {materialized_html, Map.put(live_state, :child_records, child_records)}
    end)
  end

  @spec full_render(struct(), Table.t(), keyword()) :: binary()
  def full_render(%_{} = record, %Table{} = table, opts \\ []) do
    ensure_target!(table)

    compiled = AshUi.Runtime.ResourceInfo.compiled_resource(table.resource)

    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        compiled,
        record,
        Keyword.get(opts, :params, %{}),
        render_opts(opts)
      )

    html(tree, Keyword.put(opts, :navigation_resource, table.resource))
  end

  @spec render(struct(), MapSet.t() | :all, list(), Table.t(), map(), keyword()) ::
          {[SSE.event()], map()}
  def render(%_{} = record, changed, forced, %Table{} = table, live_state, opts)
      when is_list(forced) and is_map(live_state) do
    ensure_target!(table)
    changed = merge_changed(changed, forced)

    {{events, next_state}, child_records} =
      with_child_record_cache(Map.get(live_state, :child_records, %{}), fn cache_opts ->
        opts = Keyword.merge(opts, cache_opts)

        rendered =
          measure_dispatch_layer(:render_scope, fn ->
            rendered = live_render(record, changed, live_state.table, opts)
            if changed == :all, do: memoize(rendered), else: memoize_changed(rendered)
          end)

        {diff, prints} =
          measure_dispatch_layer(:diff, fn ->
            live_diff(rendered, live_state.prints)
          end)

        {keyed, keyed_attrs} =
          measure_dispatch_layer(:keyed_snapshot, fn ->
            keyed_snapshot_changed(
              rendered,
              changed,
              diff,
              live_state.table,
              live_state.keyed,
              Map.get(live_state, :keyed_attrs, %{})
            )
          end)

        events =
          measure_dispatch_layer(:projection, fn ->
            case {changed, diff} do
              {_changed, diff} when map_size(diff) == 0 ->
                []

              {:all, _diff} ->
                [
                  # `rendered` is the post-update tree that produced both the
                  # diff and the retained keyed snapshot above. Materialize
                  # that memoized tree for the recovery morph instead of
                  # evaluating the same page a second time through full_render.
                  SSE.patch_elements(materialized_html(rendered, opts),
                    meta: %{region: table.root}
                  )
                ]

              {%MapSet{}, diff} ->
                project_live_diff(
                  record,
                  diff,
                  live_state.keyed,
                  keyed,
                  live_state.table,
                  table,
                  opts
                  |> Keyword.put(
                    :__bp_old_keyed_attrs__,
                    Map.get(live_state, :keyed_attrs, %{})
                  )
                  |> Keyword.put(:__bp_new_keyed_attrs__, keyed_attrs)
                )
            end
          end)

        wire_diff = prefix_diff_urls(diff, Keyword.get(opts, :base_path, ""))

        {events,
         %{
           live_state
           | prints: prints,
             diff: wire_diff,
             keyed: keyed,
             keyed_attrs: keyed_attrs
         }}
      end)

    {events, Map.put(next_state, :child_records, child_records)}
  end

  defp materialized_html(%Rendered{} = rendered, opts) do
    measure_dispatch_layer(:projection_html, fn ->
      rendered
      |> Materialize.to_iodata()
      |> IO.iodata_to_binary()
      |> prefix_bridge_urls(Keyword.get(opts, :base_path, ""))
    end)
  end

  @spec patch(struct(), MapSet.t() | :all | struct(), Table.t()) :: [SSE.event()]
  def patch(%_{} = record, %MapSet{} = changed, %Table{} = table),
    do: patch_changed(record, changed, table, [])

  def patch(%_{} = record, :all, %Table{} = table),
    do: patch_changed(record, :all, table, [])

  def patch(%_{} = old, %_{} = new, %Table{} = table),
    do: patch(old, new, table, [])

  @spec patch(struct(), struct(), list(), Table.t(), keyword()) :: [SSE.event()]
  def patch(%_{} = old, %_{} = new, forced, %Table{} = table, opts)
      when is_list(forced) do
    {_html, live_state} = initial_render(old, table, Keyword.put(opts, :errors, []))
    changed = Runtime.changed_addresses(table, old, new)
    {events, _live_state} = render(new, changed, forced, table, live_state, opts)
    events
  end

  @spec patch(struct(), MapSet.t() | :all | struct(), Table.t(), keyword()) :: [SSE.event()]
  def patch(%_{} = record, %MapSet{} = changed, %Table{} = table, opts),
    do: patch_changed(record, changed, table, opts)

  def patch(%_{} = record, :all, %Table{} = table, opts),
    do: patch_changed(record, :all, table, opts)

  def patch(%_{} = old, %_{} = new, %Table{} = table, opts) do
    patch(old, new, [], table, opts)
  end

  defp patch_changed(_record, %MapSet{} = changed, _table, _opts)
       when map_size(changed.map) == 0,
       do: []

  defp patch_changed(record, :all, table, opts) do
    {_html, live_state} = initial_render(record, table, Keyword.put(opts, :errors, []))
    {events, _live_state} = render(record, :all, [], table, live_state, opts)
    events
  end

  defp patch_changed(record, %MapSet{} = changed, table, opts) do
    {_html, live_state} = initial_render(record, table, Keyword.put(opts, :errors, []))
    {events, _live_state} = render(record, changed, [], table, live_state, opts)
    events
  end

  defp project_live_diff(
         record,
         diff,
         old_keyed,
         new_keyed,
         live_table,
         table,
         opts
       ) do
    project_skeleton(
      record,
      diff,
      old_keyed,
      new_keyed,
      live_table.skeleton,
      live_table,
      table,
      lowered(table),
      opts
    )
    |> dedupe_regions()
  end

  defp project_skeleton(
         record,
         diff,
         old_keyed,
         new_keyed,
         skeleton,
         live_table,
         table,
         source,
         opts
       )
       when is_map(diff) do
    diff
    |> Enum.filter(fn {index, _value} -> is_integer(index) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {index, live_dynamic} ->
      case Enum.at(skeleton.dynamics, index) do
        {:child, address, resource, input_eval, _embedded?} ->
          project_child(
            record,
            live_dynamic,
            old_keyed,
            new_keyed,
            address,
            resource,
            input_eval,
            live_table,
            table,
            source,
            opts
          )

        {:branch, address, condition, arms} ->
          project_branch(
            record,
            live_dynamic,
            old_keyed,
            new_keyed,
            address,
            condition,
            arms,
            live_table,
            table,
            source,
            opts
          )

        {:keyed, address, items_eval, item} ->
          slot =
            case slot_at(table, address) do
              nil ->
                %{
                  addr: address,
                  eval: items_eval,
                  kind: :keyed_list,
                  meta: item
                }

              slot ->
                %{slot | meta: Map.merge(slot.meta, item)}
            end

          chain = Keyword.get(opts, :__bp_chain__, [])

          keyed_events_from_live_diff(
            record,
            slot,
            live_dynamic,
            old_keyed,
            new_keyed,
            Map.get(old_keyed, {chain, address}, []),
            Map.get(new_keyed, {chain, address}, []),
            live_table,
            source,
            table,
            opts
          )

        {:attrs, address, _eval} ->
          case slot_at(table, address) do
            # Datastar-generated ids below keyed boundaries are runtime attrs
            # in the algebra, but they are not application-change regions.
            # Let the changed descendant slot drive projection.
            nil ->
              if String.contains?(address, "/*") do
                []
              else
                List.wrap(region_event(record, address, nil, source, table, opts))
              end

            slot ->
              List.wrap(
                island_props_event(
                  record,
                  address,
                  live_dynamic,
                  source,
                  table,
                  opts
                ) || region_event(record, address, slot, source, table, opts)
              )
          end

        {:fragment_input, _address, parent_resource, fragment_skeleton} ->
          case Keyword.get(opts, :__bp_parent_records__, []) do
            [parent_record | parent_records] ->
              parent_live_table = Compiler.table(parent_resource, target: RenderTarget)
              parent_table = Compiler.table(parent_resource, target: RenderTarget)

              project_skeleton(
                parent_record,
                live_dynamic,
                old_keyed,
                new_keyed,
                fragment_skeleton,
                parent_live_table,
                parent_table,
                lowered(parent_table),
                opts
                |> Keyword.put(:__bp_parent_records__, parent_records)
                |> Keyword.update(:__bp_chain__, [], &Enum.drop(&1, -1))
              )

            _missing_parent_record ->
              []
          end

        {_kind, address, _eval} ->
          List.wrap(region_event(record, address, slot_at(table, address), source, table, opts))

        nil ->
          []
      end
    end)
  end

  defp project_skeleton(
         _record,
         _diff,
         _old_keyed,
         _new_keyed,
         _skeleton,
         _live_table,
         _table,
         _source,
         _opts
       ),
       do: []

  defp project_child(
         record,
         live_dynamic,
         old_keyed,
         new_keyed,
         address,
         resource,
         input_eval,
         live_table,
         table,
         source,
         opts
       ) do
    parent_records = [record | Keyword.get(opts, :__bp_parent_records__, [])]

    child_chain =
      Keyword.get(opts, :__bp_chain__, []) ++ [Compiler.addr_component(address)]

    cache_opts = %{
      child_record_cache_get: Keyword.get(opts, :child_record_cache_get),
      child_record_cache_put: Keyword.get(opts, :child_record_cache_put),
      child_record_cache_boundary: {resource, child_chain}
    }

    with %{} <- live_dynamic,
         {:ok, child_record} <-
           projected_child_record(
             resource,
             input_eval,
             record,
             parent_records,
             child_chain,
             cache_opts,
             opts
           ) do
      child_live_table =
        Map.get(live_table.children, address) ||
          Compiler.table(resource, target: RenderTarget)

      child_table =
        Map.get(table.children, address) || Compiler.table(resource, target: RenderTarget)

      child_opts =
        opts
        |> Keyword.put(
          :__bp_chain__,
          child_chain
        )
        |> Keyword.put(:__bp_parent_records__, parent_records)

      child_opts =
        case slot_at(table, address) do
          %{meta: %{record: expression}} ->
            case AshUi.Runtime.ViewRender.expression_path(
                   expression,
                   Map.new(child_opts)
                 ) do
              path when is_list(path) -> Keyword.put(child_opts, :__bp_error_path__, path)
              _unknown -> child_opts
            end

          _missing ->
            child_opts
        end

      project_skeleton(
        child_record,
        live_dynamic,
        old_keyed,
        new_keyed,
        child_live_table.skeleton,
        child_live_table,
        child_table,
        lowered(child_table),
        child_opts
      )
    else
      _cannot_descend ->
        List.wrap(region_event(record, address, slot_at(table, address), source, table, opts))
    end
  end

  defp projected_child_record(
         resource,
         input_eval,
         record,
         parent_records,
         child_chain,
         cache_opts,
         opts
       ) do
    case ResourceComponentRender.fetch_cached_child_record(
           resource,
           {resource, child_chain},
           cache_opts
         ) do
      {:ok, child_record} ->
        {:ok, child_record}

      :miss ->
        input = Evaluator.eval(input_eval, scope(record, opts))

        AshUi.build_child_record(resource, input,
          parent_record: record,
          parent_records: parent_records,
          actor: Keyword.get(opts, :actor),
          tenant: Keyword.get(opts, :tenant),
          context: Keyword.get(opts, :context, %{}),
          session_id: Keyword.get(opts, :session_id),
          reuse_loaded_values?: Keyword.get(opts, :reuse_loaded_values?, false),
          child_record_cache_get: Keyword.get(opts, :child_record_cache_get),
          child_record_cache_put: Keyword.get(opts, :child_record_cache_put),
          child_record_cache_boundary: {resource, child_chain}
        )
    end
  end

  defp project_branch(
         record,
         live_dynamic,
         old_keyed,
         new_keyed,
         address,
         condition,
         arms,
         live_table,
         table,
         source,
         opts
       ) do
    switched? = is_map(live_dynamic) and Map.has_key?(live_dynamic, :s)

    if is_map(live_dynamic) and not switched? do
      arm =
        if truthy?(Evaluator.eval(condition, scope(record, opts))),
          do: arms.true,
          else: arms.false

      case arm do
        nil ->
          List.wrap(region_event(record, address, slot_at(table, address), source, table, opts))

        skeleton ->
          case project_skeleton(
                 record,
                 live_dynamic,
                 old_keyed,
                 new_keyed,
                 skeleton,
                 live_table,
                 table,
                 source,
                 opts
               ) do
            [] ->
              List.wrap(
                region_event(record, address, slot_at(table, address), source, table, opts)
              )

            events ->
              events
          end
      end
    else
      branch_switch_events(record, live_dynamic, address, condition, table, source, opts) ||
        List.wrap(region_event(record, address, slot_at(table, address), source, table, opts))
    end
  end

  # ── branch arm switches ───────────────────────────────────────────────────

  # An arm flip swaps statics (the wire diff carries `:s`), so the containing
  # element is not a minimal region: for a top-level conditional it can be the
  # whole page. When both arms consist of statically-certain element roots and
  # the branch has an adjacent always-rendered sibling to anchor on, the
  # switch is emitted as per-element removes plus one anchored insert.
  # Uncertain shapes (text/dynamic roots, no anchor) return nil and keep the
  # containing-region morph.
  defp branch_switch_events(record, live_dynamic, address, condition, table, source, opts) do
    with %{node: %{kind: :if} = node, elements: elements} <- locate(source, address),
         new_true? = truthy?(Evaluator.eval(condition, scope(record, opts))),
         {new_nodes, old_nodes} = arm_sources(node, new_true?),
         true <- arm_shape_consistent?(live_dynamic, new_nodes),
         {:ok, old_roots} <- certain_arm_roots(old_nodes),
         {:ok, new_roots} <- certain_arm_roots(new_nodes),
         false <- Enum.any?(old_roots ++ new_roots, &contains_island?/1),
         {:ok, rendered} <- arm_root_renders(new_roots, record, table, opts) do
      chain = Keyword.get(opts, :__bp_chain__, [])

      # dom ids collapse the arm segment (boundary_address), so both arms'
      # first roots share one stable id: a reused id is an in-place morph,
      # a vanished id is a remove, a fresh id is an anchored insert
      old_ids =
        Map.new(old_roots, fn root ->
          {node_id(root, Map.get(root, :__bp_addr__), chain), root}
        end)

      new_ids = MapSet.new(rendered, fn {_root, _html, id} -> id end)

      removes =
        for {id, root} <- old_ids, not MapSet.member?(new_ids, id) do
          SSE.patch_elements("",
            selector: "#" <> css_escape(id),
            mode: :remove,
            meta: %{
              region: runtime_region(chain, Map.get(root, :__bp_addr__)),
              operation: :remove,
              address: address
            }
          )
        end

      case arm_patches(rendered, old_ids, elements, address, chain) do
        :uncertain -> nil
        patches -> removes ++ patches
      end
    else
      _uncertain -> nil
    end
  end

  defp arm_root_renders(roots, record, table, opts) do
    rendered =
      Enum.map(roots, fn root ->
        case render_node(table, root, record, opts) do
          {html, id, _region} -> {root, html, id}
          nil -> nil
        end
      end)

    if Enum.any?(rendered, &is_nil/1), do: :uncertain, else: {:ok, rendered}
  end

  # the first fresh root anchors on an immediately adjacent always-rendered
  # sibling; every later root anchors after its predecessor, so multi-root
  # arms land in source order
  defp arm_patches(rendered, old_ids, elements, address, chain) do
    rendered
    |> Enum.reduce_while({[], nil}, fn {root, html, id}, {acc, prev_id} ->
      region = runtime_region(chain, Map.get(root, :__bp_addr__))

      cond do
        Map.has_key?(old_ids, id) ->
          event =
            SSE.patch_elements(html,
              selector: "#" <> css_escape(id),
              meta: %{region: region, address: address}
            )

          {:cont, {acc ++ [event], id}}

        is_binary(prev_id) ->
          event =
            SSE.patch_elements(html,
              selector: "#" <> css_escape(prev_id),
              mode: :after,
              meta: %{region: region, operation: :insert, address: address}
            )

          {:cont, {acc ++ [event], id}}

        true ->
          case branch_anchor(elements, address, chain) do
            {:ok, {selector, mode}} ->
              event =
                SSE.patch_elements(html,
                  selector: selector,
                  mode: mode,
                  meta: %{region: region, operation: :insert, address: address}
                )

              {:cont, {acc ++ [event], id}}

            :uncertain ->
              {:halt, :uncertain}
          end
      end
    end)
    |> case do
      :uncertain -> :uncertain
      {events, _prev_id} -> events
    end
  end

  defp arm_sources(node, true), do: {List.wrap(node[:then]), List.wrap(node[:else])}
  defp arm_sources(node, false), do: {List.wrap(node[:else]), List.wrap(node[:then])}

  # a binary live dynamic means the new arm rendered empty; a map carrying new
  # statics means it rendered content — anything else is not a clean switch
  defp arm_shape_consistent?(live_dynamic, new_nodes) when is_binary(live_dynamic),
    do: new_nodes == []

  defp arm_shape_consistent?(%{s: _statics}, new_nodes), do: new_nodes != []
  defp arm_shape_consistent?(_live_dynamic, _new_nodes), do: false

  defp certain_arm_roots(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case node do
        %{kind: :element} ->
          {:cont, {:ok, acc ++ [node]}}

        %{kind: :fragment} ->
          case certain_arm_roots(node |> Map.get(:children, []) |> List.wrap()) do
            {:ok, inner} -> {:cont, {:ok, acc ++ inner}}
            :uncertain -> {:halt, :uncertain}
          end

        _dynamic ->
          {:halt, :uncertain}
      end
    end)
  end

  # anchor only on an IMMEDIATELY adjacent always-rendered element: skipping
  # over dynamic siblings could place the arm on the wrong side of their
  # currently rendered content
  defp branch_anchor(elements, address, chain) do
    with %{node: parent} <- List.last(elements),
         children = flatten_fragments(parent |> Map.get(:children, []) |> List.wrap()),
         index when is_integer(index) <-
           Enum.find_index(children, &(Map.get(&1, :__bp_addr__) == address)) do
      next = Enum.at(children, index + 1)
      prev = if index > 0, do: Enum.at(children, index - 1)

      case {next, prev} do
        {%{kind: :element} = anchor, _prev} ->
          if contains_island?(anchor) do
            :uncertain
          else
            {:ok,
             {"#" <> css_escape(node_id(anchor, Map.get(anchor, :__bp_addr__), chain)), :before}}
          end

        {_next, %{kind: :element} = anchor} ->
          if contains_island?(anchor) do
            :uncertain
          else
            {:ok,
             {"#" <> css_escape(node_id(anchor, Map.get(anchor, :__bp_addr__), chain)), :after}}
          end

        _neither ->
          :uncertain
      end
    else
      _missing -> :uncertain
    end
  end

  defp flatten_fragments(nodes) do
    Enum.flat_map(nodes, fn
      %{kind: :fragment} = fragment ->
        flatten_fragments(fragment |> Map.get(:children, []) |> List.wrap())

      node ->
        [node]
    end)
  end

  # ── complete-element regions ─────────────────────────────────────────────

  # Island props are the one attrs change that cannot use the normal outer
  # element morph: the server-side island is intentionally empty while its
  # client owns the children. Apply only the changed wire attribute and let
  # the binding's MutationObserver deliver it to the root runtime.
  defp island_props_event(record, address, live_dynamic, source, table, opts) do
    with true <- island_props_diff?(live_dynamic),
         %{node: _node} = location <- locate(source, address),
         candidate <- region_candidate(location, slot_at(table, address)),
         {attrs, id, region} <- render_node_attrs(table, candidate.node, record, opts),
         value when is_binary(value) <- Map.get(attrs, "data-ash-ui-island-props") do
      script =
        "var n=document.getElementById(" <>
          script_json(id) <>
          ");if(n)n.setAttribute('data-ash-ui-island-props'," <>
          script_json(value) <>
          ");"

      SSE.execute_script(script,
        meta: %{
          region:
            runtime_region(
              Keyword.get(opts, :__bp_chain__, []),
              region || candidate.addr
            ),
          address: address,
          operation: :island_props
        }
      )
    else
      _not_island_props -> nil
    end
  end

  defp island_props_diff?(value) when is_binary(value),
    do: String.contains?(value, "data-ash-ui-island-props")

  defp island_props_diff?(value) when is_list(value),
    do: Enum.any?(value, &island_props_diff?/1)

  defp island_props_diff?(value) when is_map(value),
    do: Enum.any?(value, fn {_key, part} -> island_props_diff?(part) end)

  defp island_props_diff?(_value), do: false

  defp region_event(record, address, slot, source, table, opts) do
    with %{node: _node} = location <- locate(source, address),
         candidate <- region_candidate(location, slot),
         {html, id, region} <- render_node(table, candidate.node, record, opts) do
      SSE.patch_elements(html,
        selector: "#" <> css_escape(id),
        mode: :outer,
        meta: %{
          region:
            runtime_region(
              Keyword.get(opts, :__bp_chain__, []),
              region || candidate.addr
            ),
          address: address
        }
      )
    else
      _missing -> nil
    end
  end

  defp region_candidate(%{node: %{kind: kind}} = location, _slot)
       when kind in [:element, :resource_component],
       do: %{node: location.node, addr: location.addr}

  # A conditional can render zero, one, or several sibling roots. Datastar
  # needs one stable selector, so its smallest safe morph region is the
  # containing element rather than an arbitrary first node from the arm.
  defp region_candidate(%{node: %{kind: kind}, elements: elements} = location, _slot)
       when kind in [:if, :when],
       do: List.last(elements) || %{node: location.node, addr: location.addr}

  defp region_candidate(%{elements: [_ | _] = elements}, _slot), do: List.last(elements)
  defp region_candidate(location, _slot), do: %{node: location.node, addr: location.addr}

  defp contains_island?(%{kind: :element} = node) do
    attrs = Map.get(node, :attrs, %{})

    Map.has_key?(attrs, "data-ash-ui-island") or
      Map.has_key?(attrs, :"data-ash-ui-island") or
      Enum.any?(node |> Map.get(:children, []) |> List.wrap(), &contains_island?/1)
  end

  defp contains_island?(%{kind: :fragment} = node),
    do: Enum.any?(node |> Map.get(:children, []) |> List.wrap(), &contains_island?/1)

  defp contains_island?(%{kind: :if} = node),
    do: Enum.any?(List.wrap(node[:then]) ++ List.wrap(node[:else]), &contains_island?/1)

  defp contains_island?(%{kind: :when} = node), do: contains_island?(node.child)
  defp contains_island?(%{kind: :each} = node), do: contains_island?(node.child)
  defp contains_island?(nodes) when is_list(nodes), do: Enum.any?(nodes, &contains_island?/1)
  defp contains_island?(_node), do: false

  # ── keyed entry minimality ────────────────────────────────────────────────

  # LiveView has already compared keys, vars, fingerprints, and item dynamics.
  # This function only projects its keyed wire result onto Datastar's native
  # remove/before/append/outer operations. It does not compare row structs.
  defp keyed_events_from_live_diff(
         record,
         slot,
         %{k: live_keyed},
         old_keyed,
         new_keyed,
         old_keys,
         new_keys,
         live_table,
         source,
         table,
         opts
       ) do
    {old_keys, new_keys} =
      case {old_keys, new_keys, Map.get(live_keyed, :kc)} do
        {[], [], count} when is_integer(count) ->
          keys = slot |> entries(record, opts) |> Enum.map(& &1.key)
          if length(keys) == count, do: {keys, keys}, else: {old_keys, new_keys}

        _snapshotted ->
          {old_keys, new_keys}
      end

    old_set = MapSet.new(old_keys)
    new_set = MapSet.new(new_keys)

    removed = Enum.reject(old_keys, &MapSet.member?(new_set, &1))

    removals =
      Enum.map(removed, fn key ->
        chain = Keyword.get(opts, :__bp_chain__, [])
        id = entry_id(slot, key, chain)

        SSE.patch_elements("",
          selector: "#" <> css_escape(id),
          mode: :remove,
          meta: %{
            region: entry_region(slot, key, chain),
            operation: :remove,
            key: key
          }
        )
      end)

    # inserts render; pure moves NEVER re-render — retained rows are
    # repositioned by ONE content-free script over the final id order
    inserts = Enum.reject(new_keys, &MapSet.member?(old_set, &1))
    placed = MapSet.new(inserts)

    {new_by_key, placement_events} =
      if inserts == [] do
        {nil, []}
      else
        new_entries = entries(slot, record, opts)
        new_by_key = Map.new(new_entries, &{&1.key, &1})

        placement_events =
          Enum.map(inserts, fn key ->
            entry = Map.fetch!(new_by_key, key)
            {html, _id, region} = render_entry(table, slot, record, entry, opts)
            {selector, mode} = insertion_anchor(entry, new_entries, source, slot, opts)

            SSE.patch_elements(html,
              selector: selector,
              mode: mode,
              meta: %{region: region, operation: :insert, key: key}
            )
          end)

        {new_by_key, placement_events}
      end

    chain = Keyword.get(opts, :__bp_chain__, [])

    reorder_events =
      measure_dispatch_layer(:move_script_build, fn ->
        keyed_reorder_events(
          old_keys,
          new_keys,
          old_set,
          new_set,
          source,
          slot,
          chain
        )
      end)

    # a reorder gives the live diff one entry per moved row: key lookup must
    # be indexed, or this scan is O(rows²)
    new_key_at = List.to_tuple(new_keys)

    update_diffs =
      live_keyed
      |> Enum.flat_map(fn
        {:kc, _count} ->
          []

        {index, value} when is_integer(index) ->
          case index < tuple_size(new_key_at) do
            false ->
              []

            true ->
              key = elem(new_key_at, index)

              cond do
                MapSet.member?(placed, key) -> []
                not MapSet.member?(old_set, key) -> []
                keyed_entry_changed?(value) -> [{key, value}]
                true -> []
              end
          end

        _other ->
          []
      end)

    updates =
      case bulk_keyed_attr_event(update_diffs, new_keys, slot, live_table, opts) do
        %SSE.Event{} = event ->
          [event]

        nil ->
          new_by_key =
            new_by_key || entries(slot, record, opts) |> Map.new(&{&1.key, &1})

          Enum.flat_map(update_diffs, fn {key, value} ->
            entry = Map.fetch!(new_by_key, key)

            case project_keyed_entry(
                   record,
                   value,
                   entry,
                   slot,
                   old_keyed,
                   new_keyed,
                   live_table,
                   source,
                   table,
                   opts
                 ) do
              [] ->
                {html, id, region} = render_entry(table, slot, record, entry, opts)

                [
                  SSE.patch_elements(html,
                    selector: "#" <> css_escape(id),
                    meta: %{region: region, operation: :morph, key: key}
                  )
                ]

              events ->
                events
            end
          end)
      end

    removals ++ placement_events ++ updates ++ reorder_events
  end

  defp keyed_events_from_live_diff(
         _record,
         _slot,
         _live_dynamic,
         _old_keyed,
         _new_keyed,
         _old_keys,
         _new_keys,
         _live_table,
         _source,
         _table,
         _opts
       ),
       do: []

  defp keyed_entry_changed?(value) when is_map(value), do: true
  defp keyed_entry_changed?([_old_position, value]) when is_map(value), do: true
  defp keyed_entry_changed?(_move_or_unknown), do: false

  defp keyed_reorder_events(old_keys, new_keys, old_set, new_set, source, slot, chain) do
    old_retained = Enum.filter(old_keys, &MapSet.member?(new_set, &1))
    new_retained = Enum.filter(new_keys, &MapSet.member?(old_set, &1))

    if old_retained == new_retained do
      []
    else
      parent = source |> locate(slot.addr) |> location_elements() |> List.last()

      container_id =
        if parent,
          do: node_id(parent.node, parent.addr, chain),
          else: RenderTarget.dom_id("v", chain)

      script =
        if new_retained == Enum.reverse(old_retained) do
          final_ids = Enum.map(new_keys, &entry_id(slot, &1, chain))
          append_order_script(container_id, final_ids)
        else
          stable = longest_stable_keys(old_retained, new_retained)
          move_count = length(new_keys) - MapSet.size(stable)

          if move_count * 2 >= length(new_keys) do
            final_ids = Enum.map(new_keys, &entry_id(slot, &1, chain))
            append_order_script(container_id, final_ids)
          else
            ids_by_key = Map.new(new_keys, &{&1, entry_id(slot, &1, chain)})
            final_ids = Enum.map(new_keys, &Map.fetch!(ids_by_key, &1))
            append_script = append_order_script(container_id, final_ids)

            {moves, _anchor} =
              new_keys
              |> Enum.reverse()
              |> Enum.reduce({[], nil}, fn key, {moves, anchor} ->
                if MapSet.member?(stable, key) do
                  {moves, key}
                else
                  move = [Map.fetch!(ids_by_key, key), anchor && Map.fetch!(ids_by_key, anchor)]
                  {[move | moves], key}
                end
              end)

            move_script = anchored_move_script(container_id, Enum.reverse(moves))

            if byte_size(move_script) < byte_size(append_script),
              do: move_script,
              else: append_script
          end
        end

      [
        SSE.execute_script(script,
          meta: %{
            region: runtime_region(chain, slot.addr),
            operation: :reorder,
            keys: new_keys
          }
        )
      ]
    end
  end

  defp append_order_script(container_id, ids) do
    [
      "var p=document.getElementById(",
      Jason.encode!(container_id),
      ");",
      Jason.encode!(ids),
      ".forEach(function(i){var n=document.getElementById(i);if(n&&p)p.appendChild(n);});"
    ]
    |> IO.iodata_to_binary()
  end

  defp anchored_move_script(container_id, moves) do
    [
      "var p=document.getElementById(",
      Jason.encode!(container_id),
      ");",
      Jason.encode!(moves),
      ".forEach(function(o){var n=document.getElementById(o[0]),a=o[1]&&document.getElementById(o[1]);if(n&&p)p.insertBefore(n,a);});"
    ]
    |> IO.iodata_to_binary()
  end

  # The longest common subsequence of the old/new key orders is the LIS of
  # old positions in new order. Those entries are already stable; walking the
  # final order right-to-left moves every other entry once before its anchor.
  defp longest_stable_keys(old_keys, new_keys) do
    old_positions = old_keys |> Enum.with_index() |> Map.new()

    sequence =
      Enum.flat_map(new_keys, fn key ->
        case Map.fetch(old_positions, key) do
          {:ok, position} -> [{key, position}]
          :error -> []
        end
      end)

    {_tails, tail_indexes, predecessors, items, length} =
      sequence
      |> Enum.with_index()
      |> Enum.reduce({:array.new(), :array.new(), :array.new(), :array.new(), 0}, fn
        {{key, position}, index}, {tails, tail_indexes, predecessors, items, length} ->
          slot = lis_slot(tails, position, 0, length)
          predecessor = if slot == 0, do: nil, else: :array.get(slot - 1, tail_indexes)

          {
            :array.set(slot, position, tails),
            :array.set(slot, index, tail_indexes),
            :array.set(index, predecessor, predecessors),
            :array.set(index, key, items),
            max(length, slot + 1)
          }
      end)

    case length do
      0 ->
        MapSet.new()

      length ->
        stable_key_set(:array.get(length - 1, tail_indexes), predecessors, items, MapSet.new())
    end
  end

  defp lis_slot(_tails, _position, low, high) when low == high, do: low

  defp lis_slot(tails, position, low, high) do
    middle = div(low + high, 2)

    if :array.get(middle, tails) < position,
      do: lis_slot(tails, position, middle + 1, high),
      else: lis_slot(tails, position, low, middle)
  end

  defp stable_key_set(nil, _predecessors, _items, stable), do: stable

  defp stable_key_set(index, predecessors, items, stable) do
    stable_key_set(
      :array.get(index, predecessors),
      predecessors,
      items,
      MapSet.put(stable, :array.get(index, items))
    )
  end

  defp project_keyed_entry(
         record,
         live_entry,
         entry,
         slot,
         old_keyed,
         new_keyed,
         live_table,
         source,
         table,
         opts
       ) do
    item = slot.meta

    if projectable_nested_skeleton?(item.skeleton) do
      entry_diff =
        case live_entry do
          [_old_position, %{} = diff] -> diff
          %{} = diff -> diff
          _move_or_unknown -> %{}
        end
        |> unwrap_rooted_entry_diff(item.skeleton)

      entry_opts =
        opts
        |> Keyword.put(:item_bindings, %{item.as => entry.item})
        |> maybe_put_index(item.index, item.as, entry.index)
        |> Keyword.put(:__bp_item_paths__, entry.item_paths)
        |> Keyword.put(
          :__bp_chain__,
          Keyword.get(opts, :__bp_chain__, []) ++
            [AshUi.EventBinding.key_component(entry.key)]
        )

      project_skeleton(
        record,
        entry_diff,
        old_keyed,
        new_keyed,
        item.skeleton,
        live_table,
        table,
        source,
        entry_opts
      )
    else
      []
    end
  end

  defp unwrap_rooted_entry_diff(%{0 => %{} = diff} = wrapper, %{root?: true})
       when map_size(wrapper) == 1,
       do: diff

  defp unwrap_rooted_entry_diff(diff, _skeleton), do: diff

  # Datastar morphs complete elements, so projecting a large keyed diff as one
  # morph per changed entry multiplies shared row statics onto the wire. When a
  # large entry set changed only attr chunks (the common reorder + position
  # bookkeeping case), compare the retained full attr snapshots and apply the
  # actual attribute deltas in one script. Key movement remains the separate,
  # content-free final-order operation above.
  defp bulk_keyed_attr_event(update_diffs, new_keys, slot, live_table, opts) do
    with true <- length(update_diffs) >= @bulk_keyed_threshold,
         {:ok, groups} <-
           measure_dispatch_layer(:attribute_update_build, fn ->
             keyed_attr_groups(
               update_diffs,
               new_keys,
               slot.meta.skeleton,
               live_table,
               opts
             )
           end),
         [_first | _rest] = encoded <-
           measure_dispatch_layer(:attribute_update_encode, fn -> encode_attr_groups(groups) end) do
      script =
        measure_dispatch_layer(:attribute_update_json, fn ->
          bulk_attribute_patch_script(encoded)
        end)

      SSE.execute_script(script,
        meta: %{
          region: runtime_region(Keyword.get(opts, :__bp_chain__, []), slot.addr),
          operation: :bulk_attrs,
          count: length(update_diffs)
        }
      )
    else
      _not_safe_or_not_large -> nil
    end
  end

  @doc false
  def bulk_attribute_patch_script(encoded) when is_list(encoded) do
    "var d=document.createElement('textarea');" <>
      script_json(encoded) <>
      ".forEach(function(g){var ns=g[2].map(function(t){" <>
      "return document.getElementById(g[0]+t+g[1]);});" <>
      "ns.forEach(function(n,i){if(!n)return;" <>
      "g[3].forEach(function(a){var v=a[3][i];if(v===null)return;" <>
      "if(v===false){if(n.hasAttribute(a[0]))n.removeAttribute(a[0]);return;}" <>
      "if(v===true){v='';}else{v=a[1]+v+a[2];d.innerHTML=v;v=d.value;}" <>
      "if(n.getAttribute(a[0])!==v)n.setAttribute(a[0],v);});});});"
  end

  defp attr_only_diff?([_old_position, %{} = diff], skeleton, table),
    do: attr_only_diff?(diff, skeleton, table)

  defp attr_only_diff?(%{} = diff, skeleton, table) do
    entries = Enum.filter(diff, fn {index, _value} -> is_integer(index) end)

    entries != [] and
      length(entries) == map_size(diff) and
      Enum.all?(entries, fn {index, value} ->
        case Enum.at(skeleton.dynamics, index) do
          {:attrs, _address, _eval} ->
            is_binary(value) or is_list(value)

          {:child, address, resource, _input_eval, _embedded?} ->
            child_table =
              Map.get(table.children, address) || Compiler.table(resource, target: RenderTarget)

            attr_only_diff?(value, child_table.skeleton, child_table)

          {:fragment_input, _address, parent_resource, fragment_skeleton} ->
            parent_table = Compiler.table(parent_resource, target: RenderTarget)
            attr_only_diff?(value, fragment_skeleton, parent_table)

          _other_dynamic ->
            false
        end
      end)
  end

  defp attr_only_diff?(_diff, _skeleton, _table), do: false

  defp keyed_attr_groups(update_diffs, _new_keys, skeleton, live_table, opts) do
    base_chain = Keyword.get(opts, :__bp_chain__, [])
    base_length = length(base_chain) + 1
    old_attrs = Keyword.get(opts, :__bp_old_keyed_attrs__, %{})

    update_diffs
    |> Enum.reduce_while({:ok, %{}}, fn {key, diff}, {:ok, groups} ->
      chain = base_chain ++ [AshUi.EventBinding.key_component(key)]

      case keyed_attr_group(diff, skeleton, live_table, chain, base_length, old_attrs, groups) do
        {:ok, groups} -> {:cont, {:ok, groups}}
        :error -> {:halt, :unsafe}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, Map.new(groups, fn {leaf, ops} -> {leaf, Enum.reverse(ops)} end)}
      :unsafe -> :unsafe
    end
  end

  defp keyed_attr_group(
         [_old_position, %{} = diff],
         skeleton,
         table,
         chain,
         base_length,
         old_attrs,
         groups
       ),
       do: keyed_attr_group(diff, skeleton, table, chain, base_length, old_attrs, groups)

  defp keyed_attr_group(%{} = diff, skeleton, table, chain, base_length, old_attrs, groups) do
    diff
    |> Enum.reduce_while({:ok, groups}, fn
      {index, value}, {:ok, groups} when is_integer(index) ->
        case Enum.at(skeleton.dynamics, index) do
          {:attrs, address, _eval} when is_binary(value) or is_list(value) ->
            new_chunk = if is_binary(value), do: value, else: IO.iodata_to_binary(value)

            case Map.fetch(old_attrs, {chain, address}) do
              {:ok, old_value} ->
                keyed_attr_group_delta(
                  snapshot_chunk_binary(old_value),
                  new_chunk,
                  address,
                  chain,
                  base_length,
                  groups
                )

              :error ->
                {:halt, :error}
            end

          # A multi-part attr group diffs as a per-part map: apply it to the
          # retained parts chunk, then delta the merged before/after strings
          # exactly like the flat case.
          {:attrs, address, _eval} when is_map(value) ->
            old_value = Map.get(old_attrs, {chain, address})

            case apply_parts_diff(old_value, value) do
              {:ok, new_value} ->
                keyed_attr_group_delta(
                  old_value && snapshot_chunk_binary(old_value),
                  snapshot_chunk_binary(new_value),
                  address,
                  chain,
                  base_length,
                  groups
                )

              :error ->
                {:halt, :error}
            end

          {:child, address, resource, _input_eval, _embedded?} when is_map(value) ->
            child_table =
              Map.get(table.children, address) || Compiler.table(resource, target: RenderTarget)

            case keyed_attr_group(
                   value,
                   child_table.skeleton,
                   child_table,
                   chain ++ [Compiler.addr_component(address)],
                   base_length,
                   old_attrs,
                   groups
                 ) do
              {:ok, groups} -> {:cont, {:ok, groups}}
              :error -> {:halt, :error}
            end

          {:fragment_input, _address, parent_resource, fragment_skeleton}
          when is_map(value) ->
            parent_table = Compiler.table(parent_resource, target: RenderTarget)

            case keyed_attr_group(
                   value,
                   fragment_skeleton,
                   parent_table,
                   Enum.drop(chain, -1),
                   base_length,
                   old_attrs,
                   groups
                 ) do
              {:ok, groups} -> {:cont, {:ok, groups}}
              :error -> {:halt, :error}
            end

          _not_an_attr_diff ->
            {:halt, :error}
        end

      _metadata, acc ->
        {:cont, acc}
    end)
  end

  defp keyed_attr_group(_diff, _skeleton, _table, _chain, _base_length, _old_attrs, _groups),
    do: :error

  defp keyed_attr_group_delta(old_chunk, new_chunk, address, chain, base_length, groups) do
    cond do
      old_chunk == nil ->
        {:halt, :error}

      old_chunk == new_chunk ->
        {:cont, {:ok, groups}}

      true ->
        case attr_delta(old_chunk, new_chunk) do
          {:ok, target, [_first | _rest] = changes} ->
            leaf = {Enum.drop(chain, base_length), address}

            groups =
              Map.update(groups, leaf, [{target, changes}], &[{target, changes} | &1])

            {:cont, {:ok, groups}}

          :error ->
            {:halt, :error}
        end
    end
  end

  defp parse_attrs(chunk) do
    parse_attrs(chunk, %{})
  end

  defp attr_delta(old_chunk, new_chunk) do
    case single_attr_delta(old_chunk, new_chunk) do
      {:ok, _target, _changes} = delta ->
        delta

      :error ->
        attr_delta(old_chunk, new_chunk, old_chunk, new_chunk, nil, [])
    end
  end

  # Generated attr chunks keep attribute order stable. The large reorder case
  # changes one quoted value per chunk, so locate that value by binary prefix
  # and verify the complete suffix instead of tokenizing every unchanged attr.
  # Multi-attribute/shape changes fall through to the general scanner below.
  defp single_attr_delta(old_chunk, new_chunk) do
    with target when is_binary(target) <- quoted_attr_value(old_chunk, "id"),
         prefix_length <- :binary.longest_common_prefix([old_chunk, new_chunk]),
         true <- prefix_length < byte_size(old_chunk),
         true <- prefix_length < byte_size(new_chunk),
         head <- binary_part(old_chunk, 0, prefix_length),
         [_first | _rest] = value_markers <- :binary.matches(head, "=\""),
         {equals_at, 2} <- List.last(value_markers),
         name_head <- binary_part(head, 0, equals_at),
         [_first | _rest] = spaces <- :binary.matches(name_head, " "),
         {space_at, 1} <- List.last(spaces),
         name when name != "" <-
           binary_part(old_chunk, space_at + 1, equals_at - space_at - 1),
         old_value_start = equals_at + 2,
         new_value_start = equals_at + 2,
         {:ok, old_value, old_rest} <- quoted_value_and_rest(old_chunk, old_value_start),
         {:ok, new_value, new_rest} <- quoted_value_and_rest(new_chunk, new_value_start),
         true <- old_rest == new_rest,
         true <- old_value != new_value do
      {:ok, target, [{name, new_value}]}
    else
      _not_one_stable_quoted_attr -> :error
    end
  end

  defp quoted_attr_value(chunk, name) do
    marker = [" ", name, "=\""] |> IO.iodata_to_binary()

    case :binary.match(chunk, marker) do
      {at, size} ->
        start = at + size

        case quoted_value_and_rest(chunk, start) do
          {:ok, value, _rest} -> value
          :error -> nil
        end

      :nomatch ->
        nil
    end
  end

  defp quoted_value_and_rest(chunk, start) do
    tail = binary_part(chunk, start, byte_size(chunk) - start)

    case :binary.match(tail, "\"") do
      {size, 1} ->
        value = binary_part(tail, 0, size)
        rest = binary_part(tail, size + 1, byte_size(tail) - size - 1)
        {:ok, value, rest}

      :nomatch ->
        :error
    end
  end

  defp attr_delta(old_chunk, new_chunk, old_original, new_original, target, changes) do
    case {next_attr(old_chunk), next_attr(new_chunk)} do
      {:done, :done} when is_binary(target) ->
        {:ok, target, Enum.reverse(changes)}

      {{:ok, name, old_value, old_rest}, {:ok, name, new_value, new_rest}} ->
        target = if name == "id", do: old_value, else: target
        changes = if old_value == new_value, do: changes, else: [{name, new_value} | changes]

        if old_value != new_value and
             skip_attr_space(old_rest) == skip_attr_space(new_rest) and
             is_binary(target) do
          {:ok, target, Enum.reverse(changes)}
        else
          attr_delta(old_rest, new_rest, old_original, new_original, target, changes)
        end

      _different_attribute_shape ->
        old = parse_attrs(old_original)
        new = parse_attrs(new_original)
        target = Map.get(old, "id")
        changes = attr_changes(old, new)

        if is_binary(target) and changes != [], do: {:ok, target, changes}, else: :error
    end
  end

  defp next_attr(chunk) do
    case skip_attr_space(chunk) do
      "" ->
        :done

      chunk ->
        case :binary.match(chunk, ["=", " ", "\t", "\n", "\r"]) do
          {size, 1} ->
            name = binary_part(chunk, 0, size)
            separator = :binary.at(chunk, size)
            rest = binary_part(chunk, size + 1, byte_size(chunk) - size - 1)

            if separator == ?= do
              {value, rest} = take_attr_value(rest)
              {:ok, name, value, rest}
            else
              {:ok, name, true, rest}
            end

          :nomatch ->
            {:ok, chunk, true, ""}
        end
    end
  end

  defp parse_attrs(chunk, attrs) do
    case skip_attr_space(chunk) do
      "" ->
        attrs

      chunk ->
        case :binary.match(chunk, ["=", " ", "\t", "\n", "\r"]) do
          {size, 1} ->
            name = binary_part(chunk, 0, size)
            separator = :binary.at(chunk, size)
            rest = binary_part(chunk, size + 1, byte_size(chunk) - size - 1)

            if separator == ?= do
              {value, rest} = take_attr_value(rest)
              parse_attrs(rest, Map.put(attrs, name, value))
            else
              parse_attrs(rest, Map.put(attrs, name, true))
            end

          :nomatch ->
            Map.put(attrs, chunk, true)
        end
    end
  end

  defp skip_attr_space(<<char, rest::binary>>) when char in [32, 9, 10, 13],
    do: skip_attr_space(rest)

  defp skip_attr_space(rest), do: rest

  defp take_attr_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    case :binary.match(rest, <<quote>>) do
      {size, 1} ->
        value = binary_part(rest, 0, size)
        tail = binary_part(rest, size + 1, byte_size(rest) - size - 1)
        {value, tail}

      :nomatch ->
        {rest, ""}
    end
  end

  defp take_attr_value(rest) do
    case :binary.match(rest, [" ", "\t", "\n", "\r"]) do
      {size, 1} ->
        value = binary_part(rest, 0, size)
        tail = binary_part(rest, size + 1, byte_size(rest) - size - 1)
        {value, tail}

      :nomatch ->
        {rest, ""}
    end
  end

  defp attr_changes(old, new) do
    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      case {Map.fetch(old, name), Map.fetch(new, name)} do
        {{:ok, value}, {:ok, value}} -> []
        {{:ok, _old}, :error} -> [{name, :remove}]
        {_old, {:ok, value}} -> [{name, value}]
      end
    end)
  end

  defp encode_attr_groups(groups) do
    groups
    |> Enum.sort_by(fn {leaf, _ops} -> leaf end)
    |> Enum.map(fn {_leaf, ops} ->
      targets = Enum.map(ops, &elem(&1, 0))
      {target_prefix, target_suffix, target_middles} = affix_encode(targets)

      attrs = encode_group_attrs(ops)

      [target_prefix, target_suffix, target_middles, attrs]
    end)
  end

  # A keyed reorder normally changes one position-dependent attribute per leaf.
  # Avoid building and searching a distinct attribute-name list for that hot path.
  defp encode_group_attrs([{_target, [{name, _value}]} | _rest] = ops) do
    case single_attr_values(ops, name, []) do
      {:ok, values} -> [encode_attr_values(name, Enum.reverse(values))]
      :error -> encode_group_attrs_generic(ops)
    end
  end

  defp encode_group_attrs(ops), do: encode_group_attrs_generic(ops)

  defp single_attr_values([], _name, values), do: {:ok, values}

  defp single_attr_values([{_target, [{name, :remove}]} | rest], name, values),
    do: single_attr_values(rest, name, [false | values])

  defp single_attr_values([{_target, [{name, value}]} | rest], name, values),
    do: single_attr_values(rest, name, [value | values])

  defp single_attr_values(_ops, _name, _values), do: :error

  defp encode_group_attrs_generic(ops) do
    ops
    |> Enum.flat_map(fn {_target, changes} -> Enum.map(changes, &elem(&1, 0)) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      values =
        Enum.map(ops, fn {_target, changes} ->
          case List.keyfind(changes, name, 0) do
            nil -> nil
            {^name, :remove} -> false
            {^name, value} -> value
          end
        end)

      encode_attr_values(name, values)
    end)
  end

  defp encode_attr_values(name, values) do
    binaries = Enum.filter(values, &is_binary/1)
    {prefix, suffix, _middles} = affix_encode(binaries)

    encoded =
      Enum.map(values, fn
        value when is_binary(value) -> trim_affixes(value, prefix, suffix)
        value -> value
      end)

    [name, prefix, suffix, encoded]
  end

  defp affix_encode([]), do: {"", "", []}

  defp affix_encode(strings) do
    prefix = common_prefix(strings)
    suffix = common_suffix(strings, byte_size(prefix))

    {prefix, suffix, Enum.map(strings, &trim_affixes(&1, prefix, suffix))}
  end

  defp common_prefix([first | _rest] = strings) do
    length = :binary.longest_common_prefix(strings)
    valid_prefix(first, length)
  end

  defp common_suffix([first | rest] = strings, prefix_size) do
    max_length =
      Enum.reduce(rest, byte_size(first) - prefix_size, fn value, shortest ->
        min(shortest, byte_size(value) - prefix_size)
      end)

    length = min(:binary.longest_common_suffix(strings), max_length)
    valid_suffix(first, length)
  end

  defp valid_prefix(_value, 0), do: ""

  defp valid_prefix(value, length) do
    prefix = binary_part(value, 0, length)
    if String.valid?(prefix), do: prefix, else: valid_prefix(value, length - 1)
  end

  defp valid_suffix(_value, 0), do: ""

  defp valid_suffix(value, length) do
    suffix = binary_part(value, byte_size(value) - length, length)
    if String.valid?(suffix), do: suffix, else: valid_suffix(value, length - 1)
  end

  defp trim_affixes(value, prefix, suffix) do
    prefix_size = byte_size(prefix)
    middle_size = byte_size(value) - prefix_size - byte_size(suffix)
    binary_part(value, prefix_size, middle_size)
  end

  defp script_json(value) do
    json = Jason.encode!(value)

    case :binary.match(json, ["<", ">", "&", <<0xE2, 0x80, 0xA8>>, <<0xE2, 0x80, 0xA9>>]) do
      :nomatch ->
        json

      {_at, _length} ->
        json
        |> String.replace("<", "\\u003c")
        |> String.replace(">", "\\u003e")
        |> String.replace("&", "\\u0026")
        |> String.replace(<<0xE2, 0x80, 0xA8>>, "\\u2028")
        |> String.replace(<<0xE2, 0x80, 0xA9>>, "\\u2029")
    end
  end

  defp entries(slot, record, opts) do
    item = slot.meta
    parent_scope = scope(record, opts)
    values = slot.eval |> Evaluator.eval(parent_scope) |> List.wrap()

    values
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      item_scope = put_item_scope(parent_scope, item, value, index)

      key =
        case item.key_eval do
          nil -> Keys.entry_key(value, index)
          evaluator -> Keys.entry_key(value, index, evaluator, item_scope)
        end

      %{
        key: key,
        item: value,
        index: index,
        item_paths: Map.get(item_scope.context, :__bp_item_paths__, %{})
      }
    end)
  end

  defp render_entry(table, slot, record, entry, opts) do
    item = slot.meta

    chain =
      Keyword.get(opts, :__bp_chain__, []) ++
        [AshUi.EventBinding.key_component(entry.key)]

    case render_node(
           table,
           item.item_template,
           record,
           opts
           |> Keyword.put(:item_bindings, %{item.as => entry.item})
           |> maybe_put_index(item.index, item.as, entry.index)
           |> Keyword.put(:__bp_item_paths__, entry.item_paths)
           |> Keyword.put(:__bp_chain__, chain)
         ) do
      {html, id, region} -> {html, id, runtime_region(chain, region)}
      nil -> nil
    end
  end

  defp insertion_anchor(entry, entries, source, slot, opts) do
    chain = Keyword.get(opts, :__bp_chain__, [])

    case Enum.at(entries, entry.index + 1) do
      %{key: next_key} ->
        {"#" <> css_escape(entry_id(slot, next_key, chain)), :before}

      nil ->
        parent = source |> locate(slot.addr) |> location_elements() |> List.last()

        parent_id =
          if parent,
            do: node_id(parent.node, parent.addr, chain),
            else: RenderTarget.dom_id("v", chain)

        {"#" <> css_escape(parent_id), :append}
    end
  end

  defp entry_id(slot, key, chain) do
    entry_chain = chain ++ [AshUi.EventBinding.key_component(key)]

    case slot.meta.item_template do
      %{kind: :resource_component, __bp_addr__: address} ->
        RenderTarget.dom_id("v", entry_chain ++ [Compiler.addr_component(address)])

      template ->
        root_addr = first_element_address(template) || slot.addr <> "/*/0"
        RenderTarget.dom_id(root_addr, entry_chain)
    end
  end

  defp entry_region(slot, key, chain) do
    root_addr = first_element_address(slot.meta.item_template) || slot.addr <> "/*/0"
    runtime_region(chain ++ [AshUi.EventBinding.key_component(key)], root_addr)
  end

  # one evaluation shared by every traversal of a mount-time structure
  defp memoize(%Rendered{} = rendered) do
    dynamics = rendered.dynamic.(false) |> Enum.map(&memoize/1)
    %{rendered | dynamic: fn _track_changes? -> dynamics end}
  end

  defp memoize(%Comprehension{} = comprehension) do
    entries =
      Enum.map(comprehension.entries, fn {key, vars, render} ->
        dynamics = render.(%{}, false) |> Enum.map(&memoize/1)
        {key, vars, fn _vars_changed, _track_changes? -> dynamics end}
      end)

    %{comprehension | entries: entries}
  end

  defp memoize(other), do: other

  # A dispatch evaluates only changed root dynamics. Retain that evaluation so
  # the diff and the incremental keyed snapshot share it without forcing the
  # unchanged page (especially large keyed collections) through `dynamic(false)`.
  defp memoize_changed(%Rendered{} = rendered) do
    original_dynamic = rendered.dynamic
    dynamics = original_dynamic.(true) |> Enum.map(&memoize_changed/1)

    %{
      rendered
      | dynamic: fn
          true -> dynamics
          false -> original_dynamic.(false)
        end
    }
  end

  defp memoize_changed(other), do: other

  defp live_render(record, changed, live_table, opts) do
    AshUi.Render.build(
      record,
      changed,
      opts
      |> Keyword.put(:table, live_table)
      |> Keyword.put(:target, RenderTarget)
    )
  end

  defp live_diff(rendered, prints) do
    Diff.render(rendered, prints)
  end

  defp keyed_snapshot(%Rendered{} = rendered, live_table) do
    keyed_snapshot(rendered, live_table.skeleton, live_table, [], 0, %{}, %{})
  end

  defp keyed_snapshot_changed(rendered, :all, _diff, live_table, _old_keyed, _old_attrs),
    do: keyed_snapshot(rendered, live_table)

  defp keyed_snapshot_changed(
         %Rendered{} = rendered,
         %MapSet{},
         diff,
         live_table,
         old_keyed,
         old_attrs
       ) do
    keyed_snapshot_changed(
      rendered,
      live_table.skeleton,
      diff,
      live_table,
      [],
      0,
      old_keyed,
      old_attrs
    )
  end

  defp keyed_snapshot_changed(
         %Rendered{} = rendered,
         skeleton,
         diff,
         live_table,
         chain,
         keyed_depth,
         snapshot,
         attrs
       ) do
    if not is_map(diff) or Map.has_key?(diff, :s) do
      {snapshot, attrs} = drop_snapshot_chain({snapshot, attrs}, chain)

      keyed_snapshot(
        rendered,
        skeleton,
        live_table,
        chain,
        keyed_depth,
        snapshot,
        attrs
      )
    else
      keyed_snapshot_changed_dynamics(
        rendered,
        skeleton,
        diff,
        live_table,
        chain,
        keyed_depth,
        snapshot,
        attrs
      )
    end
  end

  defp keyed_snapshot_changed_dynamics(
         %Rendered{} = rendered,
         skeleton,
         diff,
         live_table,
         chain,
         keyed_depth,
         snapshot,
         attrs
       ) do
    rendered.dynamic.(true)
    |> Enum.zip(skeleton.dynamics)
    |> Enum.with_index()
    |> Enum.reduce({snapshot, attrs}, fn
      {{nil, _dynamic}, _index}, acc ->
        acc

      {{%Comprehension{} = comprehension, {:keyed, address, _items_eval, item} = dynamic}, index},
      acc ->
        update_keyed_snapshot(
          comprehension,
          dynamic,
          live_dynamic(diff, index),
          address,
          item,
          live_table,
          chain,
          keyed_depth,
          acc
        )

      {{%Rendered{} = child, {:child, address, resource, _input_eval, _embedded?}}, index}, acc ->
        child_chain = chain ++ [Compiler.addr_component(address)]

        child_table =
          Map.get(live_table.children, address) ||
            Compiler.table(resource, target: RenderTarget)

        keyed_snapshot_changed(
          child,
          child_table.skeleton,
          live_dynamic(diff, index),
          child_table,
          child_chain,
          keyed_depth,
          elem(acc, 0),
          elem(acc, 1)
        )

      {{%Rendered{} = fragment, {:fragment_input, _address, parent_resource, fragment_skeleton}},
       index},
      acc ->
        parent_chain = Enum.drop(chain, -1)
        parent_table = Compiler.table(parent_resource, target: RenderTarget)

        keyed_snapshot_changed(
          fragment,
          fragment_skeleton,
          live_dynamic(diff, index),
          parent_table,
          parent_chain,
          keyed_depth,
          elem(acc, 0),
          elem(acc, 1)
        )

      {{%Rendered{} = branch, {:branch, address, _condition, arms} = dynamic}, _index}, acc ->
        if keyed_depth > 0 or
             Enum.any?([arms.true, arms.false], &(&1 && nested_live_skeleton?(&1))) do
          {snapshot, attrs} = drop_snapshot_region(acc, chain, address)
          single_rendered = %{rendered | dynamic: fn _track_changes? -> [branch] end}
          single_skeleton = %{skeleton | dynamics: [dynamic]}

          keyed_snapshot(
            single_rendered,
            single_skeleton,
            live_table,
            chain,
            keyed_depth,
            snapshot,
            attrs
          )
        else
          acc
        end

      {{value, {:attrs, address, eval}}, _index}, {snapshot, attrs} ->
        if keyed_depth > 0 and snapshot_attr?(eval) do
          value = snapshot_attr_value(value)
          {snapshot, Map.put(attrs, {chain, address}, value)}
        else
          {snapshot, attrs}
        end

      _unchanged_or_untracked, acc ->
        acc
    end)
  end

  # A one-entry edit still changes the parent array attribute, so the keyed
  # comprehension itself is re-evaluated. The retained key/attribute snapshot
  # must follow that result, but rebuilding every unchanged entry makes an
  # otherwise local edit array-scale. LiveView's keyed diff has already named
  # the inserted/changed entry indexes; refresh only those entry snapshots and
  # prune removed chains. Broad changes keep the one-pass rebuild below.
  defp update_keyed_snapshot(
         %Comprehension{entries: entries} = comprehension,
         dynamic,
         %{k: live_keyed},
         address,
         item,
         live_table,
         chain,
         keyed_depth,
         {snapshot, attrs}
       ) do
    old_keys = Map.get(snapshot, {chain, address}, [])
    new_keys = Enum.map(entries, &elem(&1, 0))
    new_key_set = MapSet.new(new_keys)
    removed = Enum.reject(old_keys, &MapSet.member?(new_key_set, &1))

    changed_count =
      Enum.count(live_keyed, fn
        {index, value} when is_integer(index) -> keyed_entry_changed?(value)
        _metadata -> false
      end)

    if changed_count + length(removed) < @bulk_keyed_threshold do
      {snapshot, attrs} =
        Enum.reduce(removed, {snapshot, attrs}, fn key, acc ->
          drop_snapshot_chain(
            acc,
            chain ++ [AshUi.EventBinding.key_component(key)]
          )
        end)

      snapshot = Map.put(snapshot, {chain, address}, new_keys)

      if nested_live_skeleton?(item.skeleton) do
        entries_by_index =
          entries
          |> Enum.with_index()
          |> Map.new(fn {entry, index} -> {index, entry} end)

        Enum.reduce(live_keyed, {snapshot, attrs}, fn
          {index, value}, acc when is_integer(index) ->
            if keyed_entry_changed?(value) do
              case Map.get(entries_by_index, index) do
                {key, _vars, render} ->
                  entry_chain =
                    chain ++ [AshUi.EventBinding.key_component(key)]

                  refresh_keyed_entry_snapshot(
                    value,
                    render,
                    comprehension,
                    item,
                    live_table,
                    entry_chain,
                    keyed_depth,
                    acc
                  )

                nil ->
                  acc
              end
            else
              acc
            end

          _metadata, acc ->
            acc
        end)
      else
        {snapshot, attrs}
      end
    else
      case patch_keyed_attr_snapshot(
             live_keyed,
             entries,
             old_keys,
             new_keys,
             item.skeleton,
             live_table,
             chain,
             attrs
           ) do
        {:ok, attrs} ->
          {Map.put(snapshot, {chain, address}, new_keys), attrs}

        :error ->
          rebuild_keyed_snapshot(
            comprehension,
            dynamic,
            address,
            live_table,
            chain,
            keyed_depth,
            snapshot,
            attrs
          )
      end
    end
  end

  defp update_keyed_snapshot(
         _comprehension,
         _dynamic,
         _live_dynamic,
         _address,
         _item,
         _live_table,
         _chain,
         _keyed_depth,
         acc
       ),
       do: acc

  defp refresh_keyed_entry_snapshot(
         value,
         render,
         comprehension,
         item,
         live_table,
         entry_chain,
         keyed_depth,
         {snapshot, attrs} = acc
       ) do
    if attr_only_diff?(value, item.skeleton, live_table) do
      case patch_attr_snapshot(value, item.skeleton, live_table, entry_chain, attrs) do
        {:ok, attrs} ->
          {snapshot, attrs}

        :error ->
          rebuild_keyed_entry_snapshot(
            render,
            comprehension,
            item,
            live_table,
            entry_chain,
            keyed_depth,
            acc
          )
      end
    else
      rebuild_keyed_entry_snapshot(
        render,
        comprehension,
        item,
        live_table,
        entry_chain,
        keyed_depth,
        acc
      )
    end
  end

  defp rebuild_keyed_entry_snapshot(
         render,
         comprehension,
         item,
         live_table,
         entry_chain,
         keyed_depth,
         acc
       ) do
    {snapshot, attrs} = drop_snapshot_chain(acc, entry_chain)

    entry_rendered = %Rendered{
      static: comprehension.static,
      dynamic: fn _track_changes? -> render.(%{}, false) end,
      fingerprint: comprehension.fingerprint,
      root: false
    }

    keyed_snapshot(
      entry_rendered,
      item.skeleton,
      live_table,
      entry_chain,
      keyed_depth + 1,
      snapshot,
      attrs
    )
  end

  # A broad reorder can change one generated attr chunk per entry. The native
  # keyed diff already contains those final chunks, so fold them into the
  # retained snapshot instead of evaluating every entry a second time.
  defp patch_keyed_attr_snapshot(
         live_keyed,
         _entries,
         old_keys,
         new_keys,
         skeleton,
         live_table,
         chain,
         attrs
       ) do
    if length(old_keys) == length(new_keys) and
         MapSet.new(old_keys) == MapSet.new(new_keys) do
      keys_by_index = List.to_tuple(new_keys)

      Enum.reduce_while(live_keyed, {:ok, attrs}, fn
        {:kc, _count}, acc ->
          {:cont, acc}

        {index, value}, {:ok, attrs} when is_integer(index) ->
          if keyed_entry_changed?(value) do
            case index < tuple_size(keys_by_index) do
              true ->
                key = elem(keys_by_index, index)

                entry_chain =
                  chain ++ [AshUi.EventBinding.key_component(key)]

                case patch_attr_snapshot(value, skeleton, live_table, entry_chain, attrs) do
                  {:ok, attrs} -> {:cont, {:ok, attrs}}
                  :error -> {:halt, :error}
                end

              false ->
                {:halt, :error}
            end
          else
            {:cont, {:ok, attrs}}
          end

        _metadata, acc ->
          {:cont, acc}
      end)
    else
      :error
    end
  end

  defp patch_attr_snapshot([_old_position, %{} = diff], skeleton, table, chain, attrs),
    do: patch_attr_snapshot(diff, skeleton, table, chain, attrs)

  defp patch_attr_snapshot(%{} = diff, skeleton, table, chain, attrs) do
    diff
    |> Enum.reduce_while({:ok, attrs}, fn
      {index, value}, {:ok, attrs} when is_integer(index) ->
        case Enum.at(skeleton.dynamics, index) do
          {:attrs, address, _eval} when is_binary(value) or is_list(value) ->
            value = if is_binary(value), do: value, else: IO.iodata_to_binary(value)
            {:cont, {:ok, Map.put(attrs, {chain, address}, value)}}

          {:attrs, address, _eval} when is_map(value) ->
            key = {chain, address}

            case apply_parts_diff(Map.get(attrs, key), value) do
              {:ok, new_value} -> {:cont, {:ok, Map.put(attrs, key, new_value)}}
              :error -> {:halt, :error}
            end

          {:child, address, resource, _input_eval, _embedded?} when is_map(value) ->
            child_table =
              Map.get(table.children, address) ||
                Compiler.table(resource, target: RenderTarget)

            case patch_attr_snapshot(
                   value,
                   child_table.skeleton,
                   child_table,
                   chain ++ [Compiler.addr_component(address)],
                   attrs
                 ) do
              {:ok, attrs} -> {:cont, {:ok, attrs}}
              :error -> {:halt, :error}
            end

          {:fragment_input, _address, parent_resource, fragment_skeleton}
          when is_map(value) ->
            parent_table = Compiler.table(parent_resource, target: RenderTarget)

            case patch_attr_snapshot(
                   value,
                   fragment_skeleton,
                   parent_table,
                   Enum.drop(chain, -1),
                   attrs
                 ) do
              {:ok, attrs} -> {:cont, {:ok, attrs}}
              :error -> {:halt, :error}
            end

          _not_an_attr_diff ->
            {:halt, :error}
        end

      _metadata, acc ->
        {:cont, acc}
    end)
  end

  defp patch_attr_snapshot(_diff, _skeleton, _table, _chain, _attrs), do: :error

  defp rebuild_keyed_snapshot(
         comprehension,
         dynamic,
         address,
         live_table,
         chain,
         keyed_depth,
         snapshot,
         attrs
       ) do
    {snapshot, attrs} = drop_snapshot_region({snapshot, attrs}, chain, address)
    single_rendered = %Rendered{dynamic: fn _track_changes? -> [comprehension] end}
    single_skeleton = %{dynamics: [dynamic]}

    keyed_snapshot(
      single_rendered,
      single_skeleton,
      live_table,
      chain,
      keyed_depth,
      snapshot,
      attrs
    )
  end

  defp live_dynamic(diff, index) when is_map(diff), do: Map.get(diff, index, %{})
  defp live_dynamic(_diff, _index), do: %{}

  defp drop_snapshot_chain({snapshot, attrs}, chain) do
    predicate = fn {entry_chain, _entry_address} -> chain_prefix?(chain, entry_chain) end

    {Map.reject(snapshot, fn {key, _value} -> predicate.(key) end),
     Map.reject(attrs, fn {key, _value} -> predicate.(key) end)}
  end

  defp drop_snapshot_region({snapshot, attrs}, chain, address) do
    predicate = fn {entry_chain, entry_address} ->
      chain_prefix?(chain, entry_chain) and
        (entry_address == address or address_descends_from?(entry_address, address))
    end

    {Map.reject(snapshot, fn {key, _value} -> predicate.(key) end),
     Map.reject(attrs, fn {key, _value} -> predicate.(key) end)}
  end

  defp keyed_snapshot(
         %Rendered{} = rendered,
         skeleton,
         live_table,
         chain,
         keyed_depth,
         snapshot,
         attrs
       ) do
    rendered.dynamic.(false)
    |> Enum.zip(skeleton.dynamics)
    |> Enum.reduce({snapshot, attrs}, fn
      {%Comprehension{entries: entries} = comprehension, {:keyed, address, _items_eval, item}},
      {snapshot, attrs} ->
        snapshot = Map.put(snapshot, {chain, address}, Enum.map(entries, &elem(&1, 0)))

        if nested_live_skeleton?(item.skeleton) do
          Enum.reduce(entries, {snapshot, attrs}, fn
            {key, _vars, render}, {snapshot, attrs} ->
              entry_rendered = %Rendered{
                static: comprehension.static,
                dynamic: fn _track_changes? -> render.(%{}, false) end,
                fingerprint: comprehension.fingerprint,
                root: false
              }

              keyed_snapshot(
                entry_rendered,
                item.skeleton,
                live_table,
                chain ++ [AshUi.EventBinding.key_component(key)],
                keyed_depth + 1,
                snapshot,
                attrs
              )
          end)
        else
          {snapshot, attrs}
        end

      {%Rendered{} = child, {:child, address, resource, _input_eval, _embedded?}},
      {snapshot, attrs} ->
        child_table =
          Map.get(live_table.children, address) ||
            Compiler.table(resource, target: RenderTarget)

        keyed_snapshot(
          child,
          child_table.skeleton,
          child_table,
          chain ++ [Compiler.addr_component(address)],
          keyed_depth,
          snapshot,
          attrs
        )

      {%Rendered{} = fragment, {:fragment_input, _address, parent_resource, fragment_skeleton}},
      {snapshot, attrs} ->
        parent_table = Compiler.table(parent_resource, target: RenderTarget)

        keyed_snapshot(
          fragment,
          fragment_skeleton,
          parent_table,
          Enum.drop(chain, -1),
          keyed_depth,
          snapshot,
          attrs
        )

      {%Rendered{} = branch, {:branch, _address, _condition, arms}}, {snapshot, attrs} ->
        arm =
          Enum.find([arms.true, arms.false], fn
            nil -> false
            skeleton -> skeleton.fingerprint == branch.fingerprint
          end)

        if arm,
          do: keyed_snapshot(branch, arm, live_table, chain, keyed_depth, snapshot, attrs),
          else: {snapshot, attrs}

      {value, {:attrs, address, eval}}, {snapshot, attrs} ->
        if keyed_depth > 0 and snapshot_attr?(eval) do
          value = snapshot_attr_value(value)
          {snapshot, Map.put(attrs, {chain, address}, value)}
        else
          {snapshot, attrs}
        end

      _dynamic, acc ->
        acc
    end)
  end

  defp nested_live_skeleton?(skeleton) do
    Enum.any?(skeleton.dynamics, fn
      {:keyed, _address, _items_eval, _item} ->
        true

      {:child, _address, _resource, _input_eval, _embedded?} ->
        true

      {:fragment_input, _address, _parent_resource, skeleton} ->
        nested_live_skeleton?(skeleton)

      {:branch, _address, _condition, arms} ->
        Enum.any?([arms.true, arms.false], &(&1 && nested_live_skeleton?(&1)))

      _dynamic ->
        false
    end)
  end

  # Chain-only chunks (a generated id and/or static event binding) are fixed
  # for the lifetime of a keyed entry. Retaining their full attribute binary
  # per row cannot help a later attr delta; only chunks with semantic dynamic
  # inputs need an old value in the projection snapshot.
  defp snapshot_attr?({:element_attrs, %{dynamic_attrs: dynamic_attrs}}) do
    Enum.any?(dynamic_attrs, &(not Map.get(&1, :runtime_id?, false)))
  end

  defp snapshot_attr?({:element_attrs, %{dynamic_attr: _dynamic_attr}}), do: true
  defp snapshot_attr?({:element_attrs, %{template_parts: _template_parts}}), do: false
  defp snapshot_attr?({:element_attrs, _fallback_descriptor}), do: true
  defp snapshot_attr?(_other), do: true

  # An attrs slot whose group carries several dynamic parts emits a nested
  # `Rendered` (statics + per-part dynamics), not flat iodata. Retain the
  # SHAPE ({:parts, statics, parts}) instead of a merged binary: a later
  # LiveView-shape sub-diff for the group is a per-part map
  # (`%{1 => new_part}`), and applying it to the retained parts is what
  # keeps the compact bulk/setAttribute projection alive for multi-part
  # groups — a merged binary would force any such change to bail the whole
  # keyed update to per-entry full morphs.
  defp snapshot_attr_value(%Rendered{static: statics} = rendered) do
    parts =
      rendered.dynamic.(false)
      |> Enum.map(fn
        part when is_binary(part) ->
          part

        %Rendered{} = nested ->
          nested |> Materialize.to_iodata() |> IO.iodata_to_binary()

        %AshUi.Comprehension{} = nested ->
          nested |> Materialize.to_iodata() |> IO.iodata_to_binary()

        part ->
          IO.iodata_to_binary(part)
      end)

    {:parts, statics, parts}
  end

  defp snapshot_attr_value(value) when is_binary(value), do: value
  defp snapshot_attr_value(value), do: IO.iodata_to_binary(value)

  defp snapshot_chunk_binary({:parts, statics, parts}), do: interleave_chunk(statics, parts)
  defp snapshot_chunk_binary(value) when is_binary(value), do: value

  defp interleave_chunk([static | statics], parts) do
    IO.iodata_to_binary([
      static | Enum.zip_with(parts, statics, fn part, next_static -> [part, next_static] end)
    ])
  end

  # Apply a LiveView-shape sub-diff to a retained parts chunk. A diff
  # carrying `:s` is a statics swap (the group's template changed) and ships
  # every part, so it rebuilds the chunk without needing the old value;
  # otherwise integer keys replace individual parts. Anything else —
  # missing old shape, nested non-binary parts, out-of-range indices — is
  # :error, and callers fall back to the byte-correct full-morph path.
  defp apply_parts_diff(_old, %{s: statics} = sub_diff) when is_list(statics) do
    count = length(statics) - 1

    0..(count - 1)//1
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, acc} ->
      case Map.fetch(sub_diff, index) do
        {:ok, part} when is_binary(part) -> {:cont, {:ok, [part | acc]}}
        {:ok, part} when is_list(part) -> {:cont, {:ok, [IO.iodata_to_binary(part) | acc]}}
        _missing_or_nested -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, {:parts, statics, Enum.reverse(parts)}}
      :error -> :error
    end
  end

  defp apply_parts_diff({:parts, statics, parts}, %{} = sub_diff) do
    sub_diff
    |> Enum.reduce_while({:ok, parts}, fn
      {index, part}, {:ok, parts} when is_integer(index) and index >= 0 ->
        cond do
          index >= length(parts) ->
            {:halt, :error}

          is_binary(part) ->
            {:cont, {:ok, List.replace_at(parts, index, part)}}

          is_list(part) ->
            {:cont, {:ok, List.replace_at(parts, index, IO.iodata_to_binary(part))}}

          true ->
            {:halt, :error}
        end

      {_other_key, _part}, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, new_parts} -> {:ok, {:parts, statics, new_parts}}
      :error -> :error
    end
  end

  defp apply_parts_diff(_old, _sub_diff), do: :error

  defp projectable_nested_skeleton?(skeleton) do
    Enum.any?(skeleton.dynamics, fn
      {:keyed, _address, _items_eval, _item} -> true
      {:child, _address, _resource, _input_eval, _embedded?} -> true
      {:fragment_input, _address, _parent_resource, _skeleton} -> true
      {:branch, _address, _condition, _arms} -> true
      _dynamic -> false
    end)
  end

  defp merge_changed(:all, _forced), do: :all

  defp merge_changed(%MapSet{} = changed, forced),
    do: MapSet.union(changed, MapSet.new(forced))

  # ── source and rendering helpers ─────────────────────────────────────────

  defp render_node(table, node, record, opts) do
    compiled = AshUi.Runtime.ResourceInfo.compiled_resource(table.resource)

    {:ok, tree} =
      measure_dispatch_layer(:projection_tree, fn ->
        AshUi.Runtime.Rendering.render_tree(
          %{compiled | view: node},
          record,
          Keyword.get(opts, :params, %{}),
          render_opts(opts)
        )
      end)

    case first_element(tree) do
      %Element{} = element ->
        attrs = AshUi.RenderTarget.Html.attrs(element, target: RenderTarget)
        id = Map.get(attrs, "id")
        region = Map.get(element.meta, :__bp_addr__)

        if id do
          rendered_html =
            measure_dispatch_layer(:projection_html, fn ->
              html(tree, Keyword.put(opts, :navigation_resource, table.resource))
            end)

          {rendered_html, id, region}
        else
          nil
        end

      nil ->
        nil
    end
  end

  defp render_node_attrs(table, node, record, opts) do
    compiled = AshUi.Runtime.ResourceInfo.compiled_resource(table.resource)

    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        %{compiled | view: node},
        record,
        Keyword.get(opts, :params, %{}),
        render_opts(opts)
      )

    case first_element(tree) do
      %Element{} = element ->
        attrs = AshUi.RenderTarget.Html.attrs(element, target: RenderTarget)
        id = Map.get(attrs, "id")

        if id, do: {attrs, id, Map.get(element.meta, :__bp_addr__)}, else: nil

      nil ->
        nil
    end
  end

  defp render_opts(opts) do
    [target: RenderTarget]
    |> put_opt(:actor, Keyword.get(opts, :actor))
    |> put_opt(:tenant, Keyword.get(opts, :tenant))
    |> put_opt(:context, Keyword.get(opts, :context))
    |> put_opt(:session_id, Keyword.get(opts, :session_id))
    |> put_opt(:reuse_loaded_values?, Keyword.get(opts, :reuse_loaded_values?))
    |> put_opt(:child_record_cache_get, Keyword.get(opts, :child_record_cache_get))
    |> put_opt(:child_record_cache_put, Keyword.get(opts, :child_record_cache_put))
    |> put_opt(:errors, Keyword.get(opts, :errors))
    |> put_opt(
      :__bp_all_errors__,
      Keyword.get(opts, :__bp_all_errors__, Keyword.get(opts, :errors))
    )
    |> put_opt(:__bp_error_path__, Keyword.get(opts, :__bp_error_path__))
    |> put_opt(:__bp_item_paths__, Keyword.get(opts, :__bp_item_paths__))
    |> put_opt(:__bp_parent_records__, Keyword.get(opts, :__bp_parent_records__))
    |> put_opt(:item_bindings, Keyword.get(opts, :item_bindings))
    |> put_opt(:index_bindings, Keyword.get(opts, :index_bindings))
    |> put_opt(:__bp_chain__, Keyword.get(opts, :__bp_chain__))
  end

  defp lowered(%Table{resource: resource, view: view}) do
    measure_dispatch_layer(:projection_source, fn ->
      lowered =
        resource
        |> AshUi.Compiled.view_exprs()
        |> Map.fetch!(view)
        |> AshUi.ViewConstructor.lower()

      lowered =
        if Compiler.preserve_component_boundaries?(RenderTarget),
          do: lowered,
          else: Compiler.inline_pure_children(lowered, resource)

      Compiler.stamp_addresses(lowered)
    end)
  end

  defp slot_at(%Table{slots: slots}, address), do: find_slot(slots, address)

  defp find_slot(slots, address) do
    Enum.find_value(slots, fn
      {_id, %{addr: ^address} = slot} ->
        slot

      {_id, %{kind: :keyed_list, meta: %{item_slots: item_slots}}} ->
        find_slot(item_slots, address)

      _other ->
        nil
    end)
  end

  # Locate an address while retaining its containing element nodes. The walk
  # mirrors Compiler's branch and keyed-template address scheme.
  defp locate(source, wanted), do: locate_walk(source, "v", wanted, [])

  defp locate_walk(nodes, addr, wanted, elements) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.find_value(fn {node, index} ->
      locate_walk(node, addr <> "/" <> Integer.to_string(index), wanted, elements)
    end)
  end

  defp locate_walk(%{kind: :element} = node, addr, wanted, elements) do
    elements = elements ++ [%{node: node, addr: addr}]

    if addr == wanted do
      %{node: node, addr: addr, elements: elements}
    else
      locate_walk(Map.get(node, :children, []), addr, wanted, elements)
    end
  end

  defp locate_walk(%{kind: :fragment} = node, addr, wanted, elements),
    do: locate_walk(Map.get(node, :children, []), addr, wanted, elements)

  defp locate_walk(%{kind: :if} = node, addr, wanted, elements) do
    if addr == wanted do
      %{node: node, addr: addr, elements: elements}
    else
      locate_walk(List.wrap(node[:then] || []), addr <> "/t", wanted, elements) ||
        locate_walk(List.wrap(node[:else] || []), addr <> "/f", wanted, elements)
    end
  end

  defp locate_walk(%{kind: :when} = node, addr, wanted, elements) do
    if addr == wanted,
      do: %{node: node, addr: addr, elements: elements},
      else: locate_walk(List.wrap(node.child), addr <> "/t", wanted, elements)
  end

  defp locate_walk(%{kind: :each} = node, addr, wanted, elements) do
    if addr == wanted,
      do: %{node: node, addr: addr, elements: elements},
      else: locate_walk(List.wrap(node.child), addr <> "/*", wanted, elements)
  end

  defp locate_walk(%{kind: :resource_component} = node, addr, wanted, elements) do
    if addr == wanted do
      %{node: node, addr: addr, elements: elements}
    else
      node
      |> Map.get(:assigns, %{})
      |> Enum.sort_by(fn {name, _value} -> to_string(name) end)
      |> Enum.find_value(fn {name, value} ->
        locate_walk(value, addr <> "/a" <> to_string(name), wanted, elements)
      end)
    end
  end

  defp locate_walk(node, addr, wanted, elements) do
    if addr == wanted, do: %{node: node, addr: addr, elements: elements}, else: nil
  end

  defp location_elements(%{elements: elements}), do: elements
  defp location_elements(_missing), do: []

  defp first_element(%Element{} = element), do: element

  defp first_element(%Fragment{children: children}),
    do: Enum.find_value(children, &first_element/1)

  defp first_element(%Portal{children: children}), do: Enum.find_value(children, &first_element/1)
  defp first_element(nodes) when is_list(nodes), do: Enum.find_value(nodes, &first_element/1)
  defp first_element(_other), do: nil

  defp first_element_address(%{kind: :element, __bp_addr__: addr}), do: addr

  defp first_element_address(%{kind: :fragment, children: children}),
    do: Enum.find_value(children, &first_element_address/1)

  defp first_element_address(nodes) when is_list(nodes),
    do: Enum.find_value(nodes, &first_element_address/1)

  defp first_element_address(_other), do: nil

  defp node_id(%{attrs: attrs}, addr, chain) do
    case Map.get(attrs, "id", Map.get(attrs, :id)) do
      id when is_binary(id) -> id
      _ -> RenderTarget.dom_id(addr, chain)
    end
  end

  defp runtime_region([], address), do: address
  defp runtime_region(chain, address), do: Enum.join(chain, ".") <> "|" <> address

  defp truthy?(value), do: value not in [nil, false]

  defp html(tree, opts) do
    base_path = Keyword.get(opts, :base_path, "")

    tree =
      case Keyword.get(opts, :navigation_resource) do
        resource when is_atom(resource) ->
          routes = %{
            all:
              Keyword.get_lazy(opts, :navigation_routes, fn ->
                AshUi.Location.navigation_routes(resource).all
              end),
            patch: AshUi.Location.navigation_routes(resource).patch
          }

          annotate_screen_navigation(tree, routes)

        _missing ->
          tree
      end

    {:safe, iodata} = AshUi.RenderTarget.Html.render_static(tree, target: RenderTarget)

    iodata
    |> IO.iodata_to_binary()
    |> prefix_bridge_urls(base_path)
  end

  defp annotate_screen_navigation(%Element{} = element, routes) do
    meta =
      if Map.get(element.meta, :screen_navigation?) do
        element.meta
        |> Map.put(:screen_navigation_routes, routes.all)
        |> Map.put(:screen_navigation_patch_routes, routes.patch)
      else
        element.meta
      end

    %Element{
      element
      | meta: meta,
        children: Enum.map(element.children, &annotate_screen_navigation(&1, routes))
    }
  end

  defp annotate_screen_navigation(%Fragment{} = fragment, routes),
    do: %Fragment{
      fragment
      | children: Enum.map(fragment.children, &annotate_screen_navigation(&1, routes))
    }

  defp annotate_screen_navigation(%Portal{} = portal, routes),
    do: %Portal{
      portal
      | children: Enum.map(portal.children, &annotate_screen_navigation(&1, routes))
    }

  defp annotate_screen_navigation(nodes, routes) when is_list(nodes),
    do: Enum.map(nodes, &annotate_screen_navigation(&1, routes))

  defp annotate_screen_navigation(other, _routes), do: other

  defp prefix_bridge_urls(html, ""),
    do: String.replace(html, RenderTarget.base_path_marker(), "")

  defp prefix_bridge_urls(html, base_path) do
    html
    |> String.replace(RenderTarget.base_path_marker(), base_path)
    |> String.replace(
      "/_ash_ui/dispatch/",
      base_path <> "/_ash_ui/dispatch/"
    )
    |> String.replace(
      "/_ash_ui/updates",
      base_path <> "/_ash_ui/updates"
    )
  end

  defp prefix_diff_urls(value, base_path) when is_binary(value),
    do: prefix_bridge_urls(value, base_path)

  defp prefix_diff_urls(value, base_path) when is_list(value),
    do: Enum.map(value, &prefix_diff_urls(&1, base_path))

  defp prefix_diff_urls(value, base_path) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, prefix_diff_urls(item, base_path)} end)

  defp prefix_diff_urls(value, _base_path), do: value

  defp scope(%resource{} = record, opts) do
    all_errors = Keyword.get(opts, :__bp_all_errors__, Keyword.get(opts, :errors, []))
    error_path = Keyword.get(opts, :__bp_error_path__, [])

    context =
      opts
      |> Keyword.get(:context, %{})
      |> Map.put(:__bp_all_errors__, all_errors)
      |> Map.put(:__bp_error_path__, error_path)
      |> Map.put(:__bp_binding_chain__, Keyword.get(opts, :__bp_chain__, []))
      |> Map.put(:__bp_item_paths__, Keyword.get(opts, :__bp_item_paths__, %{}))
      |> Map.put(:__bp_parent_records__, Keyword.get(opts, :__bp_parent_records__, []))

    Scope.new(record, Keyword.get(opts, :params, %{}),
      ash_resource_module: resource,
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant),
      context: context,
      errors: AshUi.errors_at_path(all_errors, error_path),
      item_bindings: Keyword.get(opts, :item_bindings, %{}),
      index_bindings: Keyword.get(opts, :index_bindings, %{})
    )
  end

  defp put_item_scope(scope, item, entry, index) do
    item_paths = Map.get(scope.context, :__bp_item_paths__, %{})

    context =
      case AshUi.Runtime.ViewRender.expression_path(
             Map.get(item, :source),
             scope.context
           ) do
        path when is_list(path) ->
          Map.put(
            scope.context,
            :__bp_item_paths__,
            Map.put(item_paths, item.as, path ++ [index])
          )

        _unknown ->
          scope.context
      end

    scope = %{
      scope
      | item_bindings: Map.put(scope.item_bindings, item.as, entry),
        context: context
    }

    if item.index in [nil, item.as],
      do: scope,
      else: %{scope | index_bindings: Map.put(scope.index_bindings, item.index, index)}
  end

  defp maybe_put_index(opts, index, as, _value) when index in [nil, as], do: opts

  defp maybe_put_index(opts, index, _as, value),
    do: Keyword.put(opts, :index_bindings, %{index => value})

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_target!(%Table{target: RenderTarget}), do: :ok

  defp ensure_target!(%Table{target: target}) do
    raise ArgumentError,
          "Datastar FragmentRender requires a table compiled for #{inspect(RenderTarget)}, got #{inspect(target)}"
  end

  # Mutable state belongs to the request adapter, never the core renderer.
  # The session map seeds request-local transport state; injected cache
  # callbacks let repeated child-boundary evaluations share the resolved row,
  # then the immutable snapshot returns to `Datastar.Store` with live state.
  defp with_child_record_cache(initial, fun) when is_map(initial) and is_function(fun, 1) do
    cache = {__MODULE__, :child_record_cache, make_ref()}
    Process.put(cache, initial)

    get = fn key ->
      case Process.get(cache, %{}) do
        %{^key => record} -> {:ok, record}
        _missing -> :miss
      end
    end

    put = fn key, record ->
      Process.put(cache, Map.put(Process.get(cache, %{}), key, record))
      :ok
    end

    try do
      result = fun.(child_record_cache_get: get, child_record_cache_put: put)
      {result, Process.get(cache, %{})}
    after
      Process.delete(cache)
    end
  end

  defp measure_dispatch_layer(layer, fun) when is_atom(layer) and is_function(fun, 0) do
    started = System.monotonic_time()

    :telemetry.execute(
      [:ash_ui, :datastar, :dispatch, :layer, :start],
      %{},
      %{layer: layer}
    )

    try do
      fun.()
    after
      :telemetry.execute(
        [:ash_ui, :datastar, :dispatch, :layer],
        %{duration: System.monotonic_time() - started},
        %{layer: layer}
      )
    end
  end

  defp dedupe_regions(events) do
    events =
      Enum.uniq_by(events, fn event ->
        {Enum.find(event.data, &String.starts_with?(&1, "selector ")),
         Map.get(event.meta, :operation, :morph)}
      end)

    Enum.reject(events, fn event ->
      Enum.any?(events, fn other ->
        # Movement and its batched attr deltas do not replace content, so
        # neither absorbs entry events inside the collection region.
        other != event and
          Map.get(other.meta, :operation) not in [:reorder, :bulk_attrs] and
          region_contains?(other.meta.region, event.meta.region)
      end)
    end)
  end

  defp region_contains?(ancestor, descendant)
       when is_binary(ancestor) and is_binary(descendant) do
    {ancestor_chain, ancestor_address} = split_region(ancestor)
    {descendant_chain, descendant_address} = split_region(descendant)

    same_or_nested_runtime =
      chain_prefix?(ancestor_chain, descendant_chain) and
        (address_descends_from?(descendant_address, ancestor_address) or
           child_chain_descends_from?(
             ancestor_chain,
             ancestor_address,
             descendant_chain
           ))

    projected_into_parent =
      ancestor_address == "v" and
        ancestor_chain
        |> Enum.reverse()
        |> Enum.find(&String.starts_with?(&1, "v-"))
        |> case do
          nil ->
            false

          child_component ->
            child_address = Compiler.decode_addr_component(child_component)

            descendant_address == child_address or
              address_descends_from?(descendant_address, child_address)
        end

    same_or_nested_runtime or projected_into_parent
  end

  defp region_contains?(_ancestor, _descendant), do: false

  defp split_region(region) do
    case String.split(region, "|", parts: 2) do
      [address] -> {[], address}
      [chain, address] -> {String.split(chain, ".", trim: true), address}
    end
  end

  defp chain_prefix?(prefix, chain),
    do: Enum.take(chain, length(prefix)) == prefix

  defp address_descends_from?(address, ancestor),
    do: String.starts_with?(address, ancestor <> "/")

  defp child_chain_descends_from?(ancestor_chain, ancestor_address, descendant_chain) do
    descendant_chain
    |> Enum.drop(length(ancestor_chain))
    |> Enum.find(&String.starts_with?(&1, "v"))
    |> case do
      nil ->
        false

      child_component ->
        child_address = Compiler.decode_addr_component(child_component)

        child_address == ancestor_address or
          address_descends_from?(child_address, ancestor_address)
    end
  end

  defp measure_mount_layer(layer, fun) when is_atom(layer) and is_function(fun, 0) do
    started = System.monotonic_time()

    :telemetry.execute(
      [:ash_ui, :mount, :layer, :start],
      %{},
      %{adapter: :datastar, layer: layer}
    )

    try do
      fun.()
    after
      :telemetry.execute(
        [:ash_ui, :mount, :layer],
        %{duration: System.monotonic_time() - started},
        %{adapter: :datastar, layer: layer}
      )
    end
  end

  # Generated ids need no escaping; authored ids may. CSS.escape-compatible
  # hexadecimal escapes are sufficient for id selectors emitted here.
  defp css_escape(id) do
    id
    |> String.to_charlist()
    |> Enum.map(fn char ->
      if char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?-, ?_] do
        <<char::utf8>>
      else
        "\\" <> Integer.to_string(char, 16) <> " "
      end
    end)
    |> IO.iodata_to_binary()
  end
end
