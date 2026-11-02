defmodule AshUi.Patch.Compiler do
  @moduledoc """
  Compiles an AshUi resource's `:view` calculation into a
  `AshUi.Patch.Table`: slots with stable addresses + a
  field→slots propagation index + keyed list anchors + child tables for
  nested `render(Resource, input)`.

  Input is the SAME lowered view the segment compiler consumes
  (`ViewConstructor.lower/1` over the persisted view expression) — one
  authored calculation, two staged evaluations (full render, patch
  emission).
  """

  alias AshUi.Expr.Compiled, as: CompiledExpr
  alias AshUi.Patch.Evaluator
  alias AshUi.Patch.Table

  @doc false
  @spec compilable?(module()) :: boolean()
  def compilable?(resource), do: AshUi.Compiled.resource_target_module?(resource)

  @doc """
  The memoized compiled patch table — the ONE table-cache API. Every
  transport calls this instead of owning a private cache (socket maps,
  per-target process-global terms, ad hoc test caches), so a table is
  compiled at most once per (blueprint, view, target, navigation routes)
  and a fat table can never ride a per-request closure. The memo itself
  lives with the other compile-time contracts in `AshUi.Compiled`.
  """
  @spec cached_table(module(), atom() | keyword(), keyword()) :: Table.t()
  def cached_table(resource, view_or_opts \\ :view, opts \\ [])

  def cached_table(resource, opts, []) when is_atom(resource) and is_list(opts),
    do: cached_table(resource, :view, opts)

  def cached_table(resource, view, opts)
      when is_atom(resource) and is_atom(view) and is_list(opts) do
    variant =
      {Keyword.get(opts, :target, AshUi.RenderTarget.Static),
       Keyword.get(opts, :navigation_routes)}

    AshUi.Compiled.cached_patch_table(resource, view, variant, fn ->
      table(resource, view, opts)
    end)
  end

  @doc """
  The compiled patch table: read from the transformer-persisted artifact
  when present (compile-time cost paid once, like compiled views), else
  compiled on demand (pure).
  """
  @spec table(module(), atom() | keyword(), keyword()) :: Table.t()
  def table(resource, view_or_opts \\ :view, opts \\ [])

  def table(resource, opts, []) when is_atom(resource) and is_list(opts),
    do: table(resource, :view, opts)

  def table(resource, view, opts)
      when is_atom(resource) and is_atom(view) and is_list(opts) do
    target = Keyword.get(opts, :target, AshUi.RenderTarget.Static)

    case compiled_table(target, resource, view) do
      %Table{} = table ->
        table

      nil ->
        case {target,
              Spark.Dsl.Extension.get_persisted(resource, :ash_ui_patch_tables, %{})} do
          {AshUi.RenderTarget.Static, %{^view => %Table{} = table}} -> table
          _other -> compile(resource, view, opts)
        end
    end
  end

  defp compiled_table(target, resource, view) do
    if function_exported?(target, :compiled_table, 2) or
         (Code.ensure_loaded?(target) and function_exported?(target, :compiled_table, 2)) do
      target.compiled_table(resource, view)
    end
  end

  @doc "Uncached compile straight from the persisted view expression."
  @spec compile(module(), atom() | keyword(), keyword()) :: Table.t()
  def compile(resource, view_or_opts \\ :view, opts \\ [])

  def compile(resource, opts, []) when is_atom(resource) and is_list(opts),
    do: compile(resource, :view, opts)

  def compile(resource, view, opts)
      when is_atom(resource) and is_atom(view) and is_list(opts) do
    target = Keyword.get(opts, :target, AshUi.RenderTarget.Static)

    navigation_routes =
      case Keyword.get(opts, :navigation_routes) do
        routes when is_list(routes) ->
          %{
            all: routes,
            patch: resource |> AshUi.Location.routes() |> Enum.map(&elem(&1, 0))
          }

        %{all: _all, patch: _patch} = routes ->
          routes

        _default ->
          AshUi.Location.navigation_routes(resource)
      end

    exprs = AshUi.Compiled.view_exprs(resource)

    expr =
      Map.get(exprs, view) ||
        raise ArgumentError,
              "#{inspect(resource)} has no #{inspect(view)} RenderTree calculation"

    # StaticCompile already lowered the canonical :view during the resource
    # transformer pass. Runtime table construction consumes that persisted IR
    # directly; lowering the authored expression again was duplicate compiler
    # work and could produce no additional information.
    lowered =
      if preserve_component_boundaries?(target) do
        AshUi.ViewConstructor.lower(expr)
      else
        case {view, AshUi.Compiled.resource!(resource)} do
          {:view, %{view: lowered}} when not is_nil(lowered) -> lowered
          _named_view -> AshUi.ViewConstructor.lower(expr)
        end
        |> inline_pure_children(resource)
      end
      |> annotate_screen_navigation(navigation_routes)
      |> stamp_addresses()

    {slots, children} =
      walk(lowered, "v", %{}, %{}, resource, MapSet.new([resource]), target, {[], false})

    {slots, root_slot_ids} = flatten_slots(slots)
    root_slots = Map.take(slots, root_slot_ids)
    propagation = propagation(root_slots, resource)

    %Table{
      resource: resource,
      view: view,
      target: target,
      slots: slots,
      root_slot_ids: root_slot_ids,
      propagation: propagation,
      propagation_addresses: propagation_addresses(propagation, slots),
      collection_slots: collection_index(root_slots),
      error_slots: error_index(root_slots),
      children: children,
      skeleton: nil,
      event_elements: event_index(lowered, resource),
      root: "v"
    }
    |> put_enriched_skeleton(
      AshUi.Patch.Skeleton.compile(resource, lowered, target: target)
    )
  end

  # ── tree walk: assign addresses, collect slots ────────────────────────────

  # An element whose attr surface has ANY dynamic input — expr attrs, state
  # conditions, a dynamic part, or event bindings (binding keys embed the
  # tree path) — carries ONE :attrs chunk slot: the whole rendered
  # attribute region re-emits together, exactly as the live host ships
  # it. Purely static elements contribute nothing.
  defp walk(
         %{kind: :element} = node,
         addr,
         slots,
         children,
         resource,
         seen,
         target,
         compile_chain
       ) do
    deps = element_attr_deps(node)

    bound_fields = bound_field_names(node)

    slots =
      if deps == :static do
        slots
      else
        eval =
          if is_nil(resource) do
            fn _scope -> nil end
          else
            element_attrs_evaluator(node, resource, addr, target)
          end

        slots =
          put_slot(
            slots,
            addr,
            :attrs,
            deps,
            eval,
            %{
              bound_fields: bound_fields
            }
          )

        # One sub-slot per expr-valued attribute (`addr@name`, owner = the
        # element): the differential renderer's attrs-chunk Rendered gates
        # each attribute pair on its own address, so a change to one attr's
        # dependency re-ships that pair alone — never the element's whole
        # attribute region (binding keys, aria, titles stay unsent). The
        # owner keeps the chunk itself in every changed set that names a
        # sub-attr, exactly like keyed/branch owners.
        node
        |> Map.get(:attrs, %{})
        |> Enum.filter(&match?({_name, %CompiledExpr{}}, &1))
        |> Enum.reduce(slots, fn {name, expression}, slots ->
          put_slot(
            slots,
            addr <> "@" <> to_string(name),
            :attrs,
            expr_deps(expression),
            evaluator(expression, resource),
            %{owner_addr: addr, sub_attr?: true}
          )
        end)
      end

    walk_children(
      Map.get(node, :children, []),
      addr,
      slots,
      children,
      resource,
      seen,
      target,
      compile_chain
    )
  end

  defp walk(
         %{kind: :text, content: %CompiledExpr{} = expr},
         addr,
         slots,
         children,
         resource,
         _seen,
         _target,
         _compile_chain
       ) do
    {put_slot(slots, addr, :text, expr.deps, evaluator(expr, resource), %{}), children}
  end

  defp walk(%{kind: :text}, _addr, slots, children, _r, _seen, _target, _compile_chain),
    do: {slots, children}

  defp walk(
         %{kind: :if} = node,
         addr,
         slots,
         children,
         resource,
         seen,
         target,
         compile_chain
       ) do
    cond_deps = expr_deps(node.condition)

    # Arms ARE walked for child-table discovery (their slots are subsumed
    # by the coarse branch slot; a render() inside an arm still needs its
    # compiled child table + child slot for input evaluation).
    {arm_slots_t, children} =
      walk_children(
        List.wrap(node[:then] || []),
        addr <> "/t",
        %{},
        children,
        resource,
        seen,
        target,
        compile_chain
      )

    {arm_slots_f, children} =
      walk_children(
        List.wrap(node[:else] || []),
        addr <> "/f",
        %{},
        children,
        resource,
        seen,
        target,
        compile_chain
      )

    # Branch slot: condition deps ONLY — a condition change re-renders the
    # taken arm whole (`:all`, the fingerprint swap on flip). Arm content
    # does NOT invalidate the branch: arm slots are FIRST-CLASS table slots
    # below, registered under their real `addr/t` / `addr/f` addresses, so
    # they take part in propagation/invalidation, error distribution, and
    # projector lookups exactly like flat slots. The renderer descends into
    # a branch whenever the changed set names the branch OR any address
    # under it (prefix rule in the emitter's skip gate), then gates arm
    # dynamics by the same changed set.
    slots =
      put_slot(
        slots,
        addr,
        :branch,
        cond_deps,
        evaluator(node.condition, resource),
        %{
          arm_slots: Map.merge(arm_slots_t, arm_slots_f)
        }
      )

    {slots |> Map.merge(arm_slots_t) |> Map.merge(arm_slots_f), children}
  end

  defp walk(
         %{kind: :each} = node,
         addr,
         slots,
         children,
         resource,
         seen,
         target,
         {static_chain, _dynamic_chain?}
       ) do
    items_deps = expr_deps(node.items)

    {item_slots, children} =
      walk_children(
        List.wrap(node.child),
        addr <> "/*",
        %{},
        children,
        resource,
        seen,
        target,
        {static_chain, true}
      )

    item_error_surface? = Enum.any?(item_slots, fn {_id, slot} -> slot.errors? end)

    # Item bodies may read parent record fields (e.g. selected_id): those
    # deps must reach the keyed slot, or a parent-only change never
    # re-renders the rows that display it.
    parent_deps =
      item_slots |> Map.values() |> Enum.flat_map(& &1.deps) |> Enum.uniq()

    parent_dep_paths =
      item_slots
      |> Map.values()
      |> Enum.flat_map(&get_in(&1, [:meta, :dep_paths]))
      |> Enum.uniq()

    slots =
      put_slot(
        slots,
        addr,
        :keyed_list,
        items_deps ++ Enum.map(parent_dep_paths, &{:state, &1}),
        evaluator(node.items, resource),
        %{
          as: node.as,
          index: node.index,
          key_eval: key_evaluator(node[:key], resource),
          parent_deps: parent_deps,
          item_deps: keyed_item_deps(node),
          item_template: node.child,
          item_slots: item_slots,
          bound_fields: if(item_error_surface?, do: [:__item__], else: [])
        }
      )

    {slots, children}
  end

  defp walk(
         %{kind: :resource_component, resource: child} = node,
         addr,
         slots,
         children,
         resource,
         seen,
         target,
         {static_chain, dynamic_chain?}
       )
       when is_atom(child) do
    input = Map.get(node, :record)

    store_deps = AshUi.ViewConstructor.rendered_store_relationship_deps(node, resource)

    {fragment_input_deps, scalar_input_deps} =
      case input do
        nil ->
          node.assigns
          |> Enum.reduce({[], store_deps}, fn {_name, value}, {fragment, scalar} ->
            deps = input_value_deps(value)

            if fragment_value?(value) do
              {deps ++ fragment, scalar}
            else
              {fragment, deps ++ scalar}
            end
          end)

        record ->
          {[], expr_deps(record) ++ store_deps}
      end

    fragment_input_deps = Enum.uniq(fragment_input_deps)
    scalar_input_deps = Enum.uniq(scalar_input_deps)
    input_deps = Enum.uniq(fragment_input_deps ++ scalar_input_deps)

    fragment_error_surface? =
      is_nil(input) and
        node.assigns
        |> Map.values()
        |> Enum.any?(fn value ->
          fragment_value?(value) and subtree_error_surface?(value)
        end)

    fragment_inputs =
      if not is_nil(resource) do
        node
        |> Map.get(:assigns, %{})
        |> Enum.flat_map(fn {name, value} ->
          if fragment_value?(value) and child_input_used?(child, name) do
            skeleton =
              AshUi.Patch.Skeleton.compile(resource, value,
                base: fragment_addr(addr, name),
                target: target,
                static_chain: static_chain,
                dynamic_chain?: dynamic_chain?
              )

            [{name, %{parent_resource: resource, skeleton: skeleton}}]
          else
            []
          end
        end)
        |> Map.new()
      else
        %{}
      end

    slots =
      put_slot(
        slots,
        addr,
        :child,
        input_deps,
        component_input_evaluator(node, resource, target),
        %{
          resource: child,
          record: input,
          fragment_inputs: fragment_inputs,
          fragment_dep_paths: state_dep_paths(fragment_input_deps),
          scalar_dep_paths: state_dep_paths(scalar_input_deps),
          bound_fields: if(fragment_error_surface?, do: [:__fragment__], else: [])
        }
      )

    children =
      if blueprint_view?(child) and not MapSet.member?(seen, child) do
        Map.put_new_lazy(children, addr, fn ->
          child_table(
            child,
            MapSet.put(seen, child),
            target,
            static_chain ++ [addr_component(addr)],
            dynamic_chain?,
            Map.get_lazy(
              node,
              :__bp_screen_navigation_routes__,
              fn -> AshUi.Location.navigation_routes(resource) end
            )
          )
        end)
      else
        children
      end

    slots = mark_child_error_surface(slots, addr, children)

    # RenderTree-valued inputs are authored in the caller's resource and
    # projected through the child. Their nested resource boundaries therefore
    # live in the caller's address space (the renderer emits the same chain),
    # so index their slots and child tables alongside the owning child slot.
    owned_slot_ids = MapSet.new(Map.keys(slots))

    {slots, children} =
      node
      |> Map.get(:assigns, %{})
      |> Enum.sort_by(fn {name, _value} -> to_string(name) end)
      |> Enum.reduce({slots, children}, fn {name, value}, {slots, children} ->
        if fragment_value?(value) and child_input_used?(child, name) do
          walk(
            value,
            fragment_addr(addr, name),
            slots,
            children,
            resource,
            seen,
            target,
            {static_chain, dynamic_chain?}
          )
        else
          {slots, children}
        end
      end)

    slots =
      Enum.reduce(slots, slots, fn {id, slot}, slots ->
        if MapSet.member?(owned_slot_ids, id) do
          slots
        else
          Map.put(slots, id, put_in(slot, [:meta, :owner_addr], addr))
        end
      end)

    {slots, children}
  end

  defp walk(
         %{kind: :fragment, children: kids},
         addr,
         slots,
         children,
         resource,
         seen,
         target,
         compile_chain
       ) do
    walk_children(kids, addr, slots, children, resource, seen, target, compile_chain)
  end

  defp walk(
         %{kind: :when} = node,
         addr,
         slots,
         children,
         resource,
         seen,
         target,
         compile_chain
       ) do
    walk(
      %{kind: :if, condition: node.condition, then: node.child, else: nil},
      addr,
      slots,
      children,
      resource,
      seen,
      target,
      compile_chain
    )
  end

  defp walk(
         %{kind: :computed, expr: %CompiledExpr{} = expr},
         addr,
         slots,
         children,
         resource,
         _seen,
         _target,
         _compile_chain
       ) do
    # Fully dynamic subtree: coarse slot, re-rendered whole on dep change.
    {put_slot(slots, addr, :branch, expr.deps, evaluator(expr, resource), %{computed: true}),
     children}
  end

  defp walk(_node, _addr, slots, children, _resource, _seen, _target, _compile_chain),
    do: {slots, children}

  defp key_evaluator(nil, _resource), do: nil
  defp key_evaluator(%CompiledExpr{} = expr, resource), do: evaluator(expr, resource)
  defp key_evaluator(_static, _resource), do: nil

  defp walk_children(kids, addr, slots, children, resource, seen, target, compile_chain)
       when is_list(kids) do
    kids
    |> Enum.with_index()
    |> Enum.reduce({slots, children}, fn {child, index}, {slots, children} ->
      walk(
        child,
        addr <> "/" <> Integer.to_string(index),
        slots,
        children,
        resource,
        seen,
        target,
        compile_chain
      )
    end)
  end

  defp walk_children(
         _kids,
         _addr,
         slots,
         children,
         _resource,
         _seen,
         _target,
         _compile_chain
       ),
       do: {slots, children}

  defp child_table(child, seen, target, static_chain, dynamic_chain?, navigation_routes) do
    exprs = AshUi.Compiled.view_exprs(child)

    case Map.get(exprs, :view) do
      nil ->
        %Table{
          resource: child,
          target: target,
          slots: %{},
          propagation: %{},
          root: "v"
        }

      expr ->
        lowered =
          if preserve_component_boundaries?(target) do
            AshUi.ViewConstructor.lower(expr)
          else
            child
            |> AshUi.Compiled.resource!()
            |> Map.fetch!(:view)
            |> inline_pure_children(child)
          end
          |> annotate_screen_navigation(navigation_routes)
          |> stamp_addresses()

        {slots, children} =
          walk(
            lowered,
            "v",
            %{},
            %{},
            child,
            seen,
            target,
            {static_chain, dynamic_chain?}
          )

        {slots, root_slot_ids} = flatten_slots(slots)
        root_slots = Map.take(slots, root_slot_ids)
        propagation = propagation(root_slots, child)

        %Table{
          resource: child,
          target: target,
          slots: slots,
          root_slot_ids: root_slot_ids,
          propagation: propagation,
          propagation_addresses: propagation_addresses(propagation, slots),
          collection_slots: collection_index(root_slots),
          error_slots: error_index(root_slots),
          children: children,
          skeleton: nil,
          event_elements: event_index(lowered, child),
          root: "v"
        }
        |> put_enriched_skeleton(
          AshUi.Patch.Skeleton.compile(child, lowered,
            target: target,
            static_chain: static_chain,
            dynamic_chain?: dynamic_chain?
          )
        )
    end
  end

  # ── address stamping ───────────────────────────────────────────────────────
  # Elements and child boundaries carry their lowered address in the node
  # itself (:__bp_addr__) — the SINGLE key language: every renderer (live
  # chunks, static target, Ash.calculate output) derives binding keys from
  # stamped addresses + the runtime item/child chain. Idempotent; the walk
  # shape mirrors event_index/1 exactly.

  @doc false
  def stamp_addresses(%{__bp_addr__: _} = lowered), do: lowered
  def stamp_addresses([%{__bp_addr__: _} | _] = lowered), do: lowered
  def stamp_addresses(lowered), do: stamp(lowered, "v")

  defp stamp(nodes, addr) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {node, index} -> stamp(node, addr <> "/" <> Integer.to_string(index)) end)
  end

  defp stamp(%{kind: :element} = node, addr) do
    node
    |> Map.put(:__bp_addr__, addr)
    |> Map.update(:children, [], &stamp_children(&1, addr))
  end

  defp stamp(%{kind: :fragment} = node, addr) do
    # The wrapper carries the addr too: fragment INPUT values re-enter
    # stamp_addresses at materialize time, and an unstamped wrapper would
    # miss the idempotency short-circuit and restamp the whole subtree in
    # a fresh address space — divorcing rendered binding keys from the
    # event index (ONE key language).
    node
    |> Map.put(:__bp_addr__, addr)
    |> Map.update(:children, [], &stamp_children(&1, addr))
  end

  defp stamp(%{kind: :if} = node, addr) do
    node
    |> Map.put(:__bp_addr__, addr)
    |> Map.update(:then, nil, &stamp_arm(&1, addr <> "/t"))
    |> Map.update(:else, nil, &stamp_arm(&1, addr <> "/f"))
  end

  defp stamp(%{kind: :when} = node, addr) do
    node
    |> Map.put(:__bp_addr__, addr)
    |> Map.update(:child, nil, &stamp_arm(&1, addr <> "/t"))
  end

  defp stamp(%{kind: :each} = node, addr) do
    node
    |> Map.put(:__bp_addr__, addr)
    |> Map.update(:child, nil, &stamp_arm(&1, addr <> "/*"))
  end

  defp stamp(%{kind: :resource_component} = node, addr) do
    node
    |> Map.put(:__bp_addr__, addr)
    |> Map.update(:assigns, %{}, fn assigns ->
      Map.new(assigns, fn {name, value} ->
        if fragment_value?(value) do
          {name, stamp(value, fragment_addr(addr, name))}
        else
          {name, value}
        end
      end)
    end)
  end

  defp stamp(node, _addr), do: node

  defp stamp_children(children, addr), do: stamp(List.wrap(children), addr)

  defp stamp_arm(nil, _addr), do: nil

  defp stamp_arm(node_or_nodes, addr) do
    case stamp(List.wrap(node_or_nodes), addr) do
      [single] when not is_list(node_or_nodes) -> single
      stamped -> stamped
    end
  end

  # ── compile-time child inlining ────────────────────────────────────────────
  # An embedded, event-free child may splice when its ordinary Ash create
  # boundary is provably an identity operation for this invocation. A child
  # containing any event boundary remains intact: the semantic renderer emits
  # that resource address in the binding chain, so removing it here would make
  # rendered keys disagree with registration-free resolution.

  @doc false
  def inline_pure_children(nodes), do: do_inline_pure_children(nodes, nil, MapSet.new(), %{})

  @doc false
  def inline_pure_children(nodes, resource) when is_atom(resource) do
    do_inline_pure_children(nodes, resource, MapSet.new([resource]), %{})
  end

  @doc false
  def preserve_component_boundaries?(target) when is_atom(target) do
    (function_exported?(target, :preserve_component_boundaries?, 0) or
       (Code.ensure_loaded?(target) and
          function_exported?(target, :preserve_component_boundaries?, 0))) and
      target.preserve_component_boundaries?()
  end

  defp do_inline_pure_children(nodes, resource, seen, item_resources) when is_list(nodes) do
    Enum.map(nodes, &do_inline_pure_children(&1, resource, seen, item_resources))
  end

  defp do_inline_pure_children(
         %{kind: :resource_component, resource: child, assigns: assigns} = node,
         resource,
         seen,
         item_resources
       )
       when is_atom(child) and is_map(assigns) do
    with true <- safe_inline_resource?(child, seen),
         true <- Map.get(node, :client, []) == [],
         true <- Map.get(node, :runtimes, []) == [],
         false <- Enum.any?(Map.values(assigns), &fragment_value?/1),
         true <- safe_inline_inputs?(assigns, child, resource, item_resources),
         %{view: _compiled} <- AshUi.Compiled.view_exprs(child),
         child_lowered <-
           child
           |> AshUi.Compiled.resource!()
           |> Map.fetch!(:view)
           |> do_inline_pure_children(child, MapSet.put(seen, child), %{}),
         true <- event_free?(child_lowered) do
      inputs = input_irs(assigns, child)

      case substitute_tree(child_lowered, inputs) do
        [single] -> single
        many when is_list(many) -> %{kind: :fragment, children: many}
        single -> single
      end
    else
      _not_inlinable -> node
    end
  end

  defp do_inline_pure_children(%{kind: :each} = node, resource, seen, item_resources) do
    item_resource =
      case Map.get(node, :items) do
        %CompiledExpr{ir: {:_ref, [], field}}
        when is_atom(resource) and not is_nil(resource) and is_atom(field) ->
          case Ash.Resource.Info.field(resource, field) do
            %{destination: destination} when is_atom(destination) and not is_nil(destination) ->
              destination

            %{type: {:array, embedded}}
            when is_atom(embedded) and not is_nil(embedded) ->
              # Only an actual Ash resource is inline-traversable as an each item.
              # A `{:array, :map}` calc (element type `Ash.Type.Map`) is a plain
              # map projection, not an embedded resource — treating it as one and
              # asking `Ash.Resource.Info.field/2` for a nested field crashes.
              if Ash.Resource.Info.resource?(embedded), do: embedded, else: nil

            _other ->
              nil
          end

        %CompiledExpr{ir: {:_item, binding, [field]}} ->
          case Map.get(item_resources, binding) do
            item when is_atom(item) and not is_nil(item) ->
              case Ash.Resource.Info.field(item, field) do
                %{destination: destination}
                when is_atom(destination) and not is_nil(destination) ->
                  destination

                %{type: {:array, embedded}}
                when is_atom(embedded) and not is_nil(embedded) ->
                  if Ash.Resource.Info.resource?(embedded), do: embedded, else: nil

                _other ->
                  nil
              end

            _unknown ->
              nil
          end

        _other ->
          nil
      end

    item_resources =
      if not is_nil(item_resource),
        do: Map.put(item_resources, node.as, item_resource),
        else: item_resources

    maybe_update(node, :child, &do_inline_pure_children(&1, resource, seen, item_resources))
  end

  defp do_inline_pure_children(%{kind: _} = node, resource, seen, item_resources) do
    node
    |> maybe_update(:children, &do_inline_pure_children(&1, resource, seen, item_resources))
    |> maybe_update(:child, &do_inline_pure_children(&1, resource, seen, item_resources))
    |> maybe_update(:then, &do_inline_pure_children(&1, resource, seen, item_resources))
    |> maybe_update(:else, &do_inline_pure_children(&1, resource, seen, item_resources))
  end

  defp do_inline_pure_children(other, _resource, _seen, _item_resources), do: other

  defp safe_inline_resource?(child, seen) do
    Code.ensure_loaded?(child) and Ash.Resource.Info.embedded?(child) and
      not MapSet.member?(seen, child) and simple_create_boundary?(child) and
      Ash.Resource.Info.relationships(child) == [] and Ash.Resource.Info.aggregates(child) == [] and
      Enum.all?(Ash.Resource.Info.calculations(child), &(&1.name == :view))
  rescue
    _error in [ArgumentError, UndefinedFunctionError] -> false
  end

  defp simple_create_boundary?(child) do
    case Ash.Resource.Info.primary_action(child, :create) do
      %{manual: nil, arguments: [], changes: []} ->
        Ash.Resource.Info.changes(child, :create) == [] and
          Ash.Resource.Info.validations(child, :create) == []

      _other ->
        false
    end
  end

  defp safe_inline_inputs?(assigns, child, resource, item_resources) do
    action = Ash.Resource.Info.primary_action(child, :create)
    inputs = Ash.Resource.Info.action_inputs(child, action.name)

    Enum.all?(Map.keys(assigns), &MapSet.member?(inputs, &1)) and
      Enum.all?(Ash.Resource.Info.attributes(child), fn attribute ->
        case Map.fetch(assigns, attribute.name) do
          {:ok, %CompiledExpr{} = expr} ->
            compatible_direct_ref?(expr, attribute, resource, item_resources)

          {:ok, literal} ->
            cast_identity?(attribute, literal)

          :error ->
            safe_literal_default?(attribute)
        end
      end)
  end

  defp compatible_direct_ref?(
         %CompiledExpr{ir: {:_ref, [], source_name}},
         target_attribute,
         resource,
         _item_resources
       )
       when is_atom(source_name) and is_atom(resource) do
    compatible_attributes?(Ash.Resource.Info.attribute(resource, source_name), target_attribute)
  rescue
    _error in [ArgumentError, UndefinedFunctionError] -> false
  end

  defp compatible_direct_ref?(
         %CompiledExpr{ir: {:_item, binding, [source_name]}},
         target_attribute,
         _resource,
         item_resources
       )
       when is_atom(source_name) do
    case Map.get(item_resources, binding) do
      item when is_atom(item) and not is_nil(item) ->
        compatible_attributes?(Ash.Resource.Info.attribute(item, source_name), target_attribute)

      _unknown ->
        false
    end
  rescue
    _error in [ArgumentError, UndefinedFunctionError] -> false
  end

  defp compatible_direct_ref?(_expr, _attribute, _resource, _item_resources), do: false

  defp compatible_attributes?(nil, _target_attribute), do: false

  defp compatible_attributes?(source_attribute, target_attribute) do
    Ash.Type.get_type(source_attribute.type) == Ash.Type.get_type(target_attribute.type) and
      source_attribute.constraints == target_attribute.constraints and
      (not source_attribute.allow_nil? or target_attribute.allow_nil?)
  end

  defp safe_literal_default?(%{default: default} = attribute)
       when not is_function(default) and
              not (is_tuple(default) and tuple_size(default) == 3 and
                     is_atom(elem(default, 0)) and is_atom(elem(default, 1)) and
                     is_list(elem(default, 2))) do
    cast_identity?(attribute, default)
  end

  defp safe_literal_default?(_attribute), do: false

  defp cast_identity?(%{allow_nil?: false}, nil), do: false

  defp cast_identity?(attribute, value) do
    with {:ok, cast} <- Ash.Type.cast_input(attribute.type, value, attribute.constraints),
         {:ok, constrained} <-
           Ash.Type.apply_constraints(attribute.type, cast, attribute.constraints) do
      constrained === value
    else
      _error -> false
    end
  end

  @doc false
  def collect_exprs(lowered), do: lowered |> collect_exprs([]) |> Enum.reverse()

  defp collect_exprs(nodes, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &collect_exprs/2)

  defp collect_exprs(%CompiledExpr{} = expr, acc), do: [expr | acc]

  defp collect_exprs(%{kind: :text, content: content}, acc),
    do: collect_exprs(content, acc)

  defp collect_exprs(%{kind: :element} = node, acc) do
    acc =
      node
      |> Map.get(:attrs, %{})
      |> Map.values()
      |> Enum.reduce(acc, &collect_exprs/2)

    collect_exprs(Map.get(node, :children, []), acc)
  end

  defp collect_exprs(%{kind: :fragment} = node, acc),
    do: collect_exprs(Map.get(node, :children, []), acc)

  defp collect_exprs(%{kind: :if} = node, acc) do
    acc = collect_exprs(node.condition, acc)
    acc = collect_exprs(List.wrap(node[:then] || []), acc)
    collect_exprs(List.wrap(node[:else] || []), acc)
  end

  defp collect_exprs(%{kind: :when} = node, acc) do
    acc = collect_exprs(node.condition, acc)
    collect_exprs(List.wrap(node.child), acc)
  end

  defp collect_exprs(%{kind: :each} = node, acc) do
    acc = collect_exprs(node.items, acc)
    acc = collect_exprs(node[:key], acc)
    collect_exprs(List.wrap(node.child), acc)
  end

  defp collect_exprs(%{kind: :computed, expr: expr}, acc), do: collect_exprs(expr, acc)

  defp collect_exprs(%{kind: :resource_component} = node, acc) do
    acc = collect_exprs(Map.get(node, :record), acc)

    node
    |> Map.get(:assigns, %{})
    |> Map.values()
    |> Enum.reduce(acc, &collect_exprs/2)
  end

  defp collect_exprs(_other, acc), do: acc

  defp maybe_update(node, key, fun) do
    case Map.get(node, key) do
      nil -> node
      value -> Map.put(node, key, fun.(value))
    end
  end

  defp event_free?(lowered), do: event_index(List.wrap(lowered)) == %{}

  # actual-argument IR per child attribute; unmapped attributes take the
  # child's declared default as a literal
  defp input_irs(assigns, child) do
    child
    |> Ash.Resource.Info.attributes()
    |> Map.new(fn attribute ->
      case Map.fetch(assigns, attribute.name) do
        {:ok, %CompiledExpr{} = expr} -> {attribute.name, expr}
        {:ok, literal} -> {attribute.name, {:literal, literal}}
        :error -> {attribute.name, {:literal, attribute.default}}
      end
    end)
  end

  defp substitute_tree(nodes, inputs) when is_list(nodes),
    do: Enum.map(nodes, &substitute_tree(&1, inputs))

  defp substitute_tree(%CompiledExpr{} = expr, inputs), do: substitute_expr(expr, inputs)

  defp substitute_tree(%{kind: :element} = node, inputs) do
    node
    |> Map.update(:attrs, %{}, fn attrs ->
      Map.new(attrs, fn {name, value} -> {name, substitute_tree(value, inputs)} end)
    end)
    |> Map.update(:states, [], fn states ->
      Enum.map(List.wrap(states), fn state ->
        maybe_update(state, :when, &substitute_tree(&1, inputs))
      end)
    end)
    |> maybe_update(:part, &substitute_tree(&1, inputs))
    |> maybe_update(:children, &substitute_tree(&1, inputs))
  end

  defp substitute_tree(%{kind: :text} = node, inputs),
    do: maybe_update(node, :content, &substitute_tree(&1, inputs))

  defp substitute_tree(%{kind: :each} = node, inputs) do
    node
    |> maybe_update(:items, &substitute_tree(&1, inputs))
    |> maybe_update(:child, &substitute_tree(&1, inputs))
  end

  defp substitute_tree(%{kind: kind} = node, inputs) when kind in [:if, :when] do
    node
    |> maybe_update(:condition, &substitute_tree(&1, inputs))
    |> maybe_update(:then, &substitute_tree(&1, inputs))
    |> maybe_update(:else, &substitute_tree(&1, inputs))
    |> maybe_update(:child, &substitute_tree(&1, inputs))
  end

  defp substitute_tree(%{kind: :resource_component} = node, inputs) do
    Map.update(node, :assigns, %{}, fn assigns ->
      Map.new(assigns, fn {name, value} -> {name, substitute_tree(value, inputs)} end)
    end)
  end

  defp substitute_tree(%{kind: :fragment} = node, inputs),
    do: maybe_update(node, :children, &substitute_tree(&1, inputs))

  defp substitute_tree(%{kind: :computed} = node, inputs),
    do: maybe_update(node, :expr, &substitute_tree(&1, inputs))

  defp substitute_tree(other, _inputs), do: other

  defp substitute_expr(%CompiledExpr{ir: ir} = expr, inputs) do
    {new_ir, used} = sub_ir(ir, inputs, MapSet.new())

    deps =
      expr.deps
      |> Enum.reject(fn
        {:state, [root | _]} when is_atom(root) -> MapSet.member?(used, root)
        {:state, root} when is_atom(root) -> MapSet.member?(used, root)
        _other -> false
      end)
      |> Kernel.++(Enum.flat_map(used, &input_deps(Map.get(inputs, &1))))
      |> Enum.uniq()

    %{expr | ir: new_ir, deps: deps}
  end

  defp input_deps(%CompiledExpr{deps: deps}), do: deps
  defp input_deps(_literal), do: []

  defp sub_ir({:_ref, [], attr} = ref, inputs, used) when is_atom(attr) do
    case Map.get(inputs, attr) do
      %CompiledExpr{ir: ir} -> {ir, MapSet.put(used, attr)}
      {:literal, value} -> {value, MapSet.put(used, attr)}
      nil -> {ref, used}
    end
  end

  defp sub_ir(list, inputs, used) when is_list(list) do
    Enum.map_reduce(list, used, &sub_ir(&1, inputs, &2))
  end

  defp sub_ir(tuple, inputs, used) when is_tuple(tuple) do
    {parts, used} =
      tuple |> Tuple.to_list() |> Enum.map_reduce(used, &sub_ir(&1, inputs, &2))

    {List.to_tuple(parts), used}
  end

  defp sub_ir(%CompiledExpr{} = nested, inputs, used) do
    {ir, used} = sub_ir(nested.ir, inputs, used)
    {%{nested | ir: ir}, used}
  end

  defp sub_ir(%{} = map, inputs, used) when not is_struct(map) do
    {pairs, used} =
      Enum.map_reduce(map, used, fn {key, value}, acc ->
        {new_value, acc} = sub_ir(value, inputs, acc)
        {{key, new_value}, acc}
      end)

    {Map.new(pairs), used}
  end

  defp sub_ir(other, _inputs, used), do: {other, used}

  # ── skeleton enrichment ────────────────────────────────────────────────────
  # Per-render lookups move to compile time: every {:child, addr, resource}
  # dynamic gains its input evaluator (resolved once from the table's child
  # slot instead of an O(slots) search per child instance per render).

  defp put_enriched_skeleton(table, skeleton) do
    table = attach_fragment_input_skeletons(table)
    %{table | skeleton: enrich(skeleton, table)}
  end

  defp attach_fragment_input_skeletons(%Table{} = table) do
    {slots, children} =
      table
      |> Table.root_slots()
      |> Enum.reduce({table.slots, table.children}, fn
        {id, %{kind: :child, addr: addr, meta: %{fragment_inputs: fragment_inputs}}},
        {slots, children}
        when map_size(fragment_inputs) > 0 ->
          case Map.get(children, addr) do
            %Table{} = child_table ->
              fragment_inputs =
                Map.new(fragment_inputs, fn {name, fragment} ->
                  {name, %{fragment | skeleton: enrich(fragment.skeleton, table)}}
                end)

              direct_fragment_inputs =
                fragment_inputs
                |> Map.keys()
                |> Enum.filter(&direct_fragment_input?(child_table, &1))

              child_table = mark_fragment_input_dynamics(child_table, fragment_inputs)

              slot =
                slots
                |> Map.fetch!(id)
                |> put_in([:meta, :fragment_inputs], fragment_inputs)
                |> put_in([:meta, :direct_fragment_inputs], direct_fragment_inputs)

              {Map.put(slots, id, slot), Map.put(children, addr, child_table)}

            _missing_child_table ->
              {slots, children}
          end

        _slot, acc ->
          acc
      end)

    %{table | slots: slots, children: children}
  end

  # A RenderTree input that reaches the child only through computed insertion
  # is already represented by the attached parent fragment skeleton. Building
  # the child record does not need to materialize that same tree first. If the
  # input also feeds a condition, attr, collection, or another calculation it
  # is not direct and retains ordinary evaluation.
  defp direct_fragment_input?(%Table{} = child_table, name) do
    case Map.get(child_table.propagation, name, []) do
      [_first | _rest] = ids ->
        Enum.all?(ids, fn id ->
          match?(%{kind: :branch, meta: %{computed: true}}, Map.fetch!(child_table.slots, id))
        end)

      [] ->
        false
    end
  end

  defp mark_fragment_input_dynamics(%Table{} = child_table, fragment_inputs) do
    replacements =
      Enum.reduce(fragment_inputs, %{}, fn {name, fragment}, replacements ->
        child_table.propagation
        |> Map.get(name, [])
        |> Enum.reduce(replacements, fn id, replacements ->
          case Map.fetch!(child_table.slots, id) do
            %{kind: :branch, meta: %{computed: true}, addr: addr} ->
              Map.put(replacements, addr, fragment)

            _not_a_render_tree_insertion ->
              replacements
          end
        end)
      end)

    %{child_table | skeleton: mark_fragment_input_dynamics(child_table.skeleton, replacements)}
  end

  defp mark_fragment_input_dynamics(nil, _replacements), do: nil

  defp mark_fragment_input_dynamics(%AshUi.Patch.Skeleton{} = skeleton, replacements) do
    dynamics =
      Enum.map(skeleton.dynamics, fn dynamic ->
        addr = elem(dynamic, 1)

        case Map.get(replacements, addr) do
          %{parent_resource: parent_resource, skeleton: fragment_skeleton} ->
            {:fragment_input, addr, parent_resource, fragment_skeleton}

          nil ->
            mark_nested_fragment_input_dynamics(dynamic, replacements)
        end
      end)

    %{skeleton | dynamics: dynamics}
  end

  defp mark_nested_fragment_input_dynamics({:branch, addr, condition, arms}, replacements) do
    {:branch, addr, condition,
     %{
       true: mark_fragment_input_dynamics(arms.true, replacements),
       false: mark_fragment_input_dynamics(arms.false, replacements)
     }}
  end

  defp mark_nested_fragment_input_dynamics({:keyed, addr, items, item}, replacements) do
    {:keyed, addr, items,
     %{item | skeleton: mark_fragment_input_dynamics(item.skeleton, replacements)}}
  end

  defp mark_nested_fragment_input_dynamics(dynamic, _replacements), do: dynamic

  defp enrich(nil, _table), do: nil

  defp enrich(%AshUi.Patch.Skeleton{} = skeleton, table) do
    %{skeleton | dynamics: Enum.map(skeleton.dynamics, &enrich_dyn(&1, table))}
  end

  defp enrich_dyn({:child, addr, resource}, table) do
    input_eval =
      case child_slot(table, addr) do
        nil -> &__MODULE__.empty_component_input/1
        slot -> slot.eval
      end

    {:child, addr, resource, input_eval, Ash.Resource.Info.embedded?(resource)}
  end

  defp enrich_dyn({:branch, addr, cond_eval, arms}, table) do
    {:branch, addr, cond_eval,
     %{true: enrich(arms.true, table), false: enrich(arms.false, table)}}
  end

  defp enrich_dyn({:keyed, addr, items_eval, item}, table) do
    {:keyed, addr, items_eval, %{item | skeleton: enrich(item.skeleton, table)}}
  end

  defp enrich_dyn(dyn, _table), do: dyn

  @doc false
  def empty_component_input(_scope), do: %{}

  # ── event element index ───────────────────────────────────────────────────
  # addr → %{node: element (children stripped), eaches: outermost-first
  # [%{items_eval, as, index}]} for every element carrying event bindings,
  # INCLUDING elements inside branch arms (addr/t, addr/f) and each item
  # templates (addr/*). This is the registration-free dispatch index: a
  # binding key names the child/item chain + the element address; resolving
  # re-evaluates the element's bindings against the CURRENT record.

  @doc false
  def event_index(lowered), do: event_index(lowered, nil)

  @doc false
  def event_index(lowered, resource),
    do:
      event_walk(
        lowered,
        "v",
        %{eaches: [], conditions: [], reload_deps: []},
        %{},
        resource
      )

  defp event_walk(nodes, addr, ctx, acc, resource) when is_list(nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {node, index}, acc ->
      event_walk(node, addr <> "/" <> Integer.to_string(index), ctx, acc, resource)
    end)
  end

  defp event_walk(%{kind: :element} = node, addr, ctx, acc, resource) do
    acc =
      case node |> Map.get(:events, []) |> List.wrap() do
        [] ->
          acc

        _events ->
          entry = %{
            node: Map.put(node, :children, []),
            eaches: ctx.eaches,
            conditions: ctx.conditions,
            reload_paths:
              state_dep_paths(
                ctx.reload_deps ++
                  List.wrap(element_attr_deps(node)) ++
                  Enum.flat_map(List.wrap(Map.get(node, :events, [])), &event_binding_deps/1)
              )
          }

          Map.put(acc, addr, entry)
      end

    event_walk_children(Map.get(node, :children, []), addr, ctx, acc, resource)
  end

  defp event_walk(%{kind: :fragment} = node, addr, ctx, acc, resource) do
    event_walk_children(Map.get(node, :children, []), addr, ctx, acc, resource)
  end

  # Reachability travels with the entry: an element in a branch arm is a
  # valid dispatch target ONLY while its arm is live — stale keys from a
  # switched-off arm must fail as ordinary unknown targets.
  defp event_walk(%{kind: :if} = node, addr, ctx, acc, resource) do
    condition = evaluator(node.condition, nil)

    acc =
      event_walk_children(
        List.wrap(node[:then] || []),
        addr <> "/t",
        %{
          ctx
          | conditions: ctx.conditions ++ [{:truthy, condition}],
            reload_deps: ctx.reload_deps ++ expr_deps(node.condition)
        },
        acc,
        resource
      )

    event_walk_children(
      List.wrap(node[:else] || []),
      addr <> "/f",
      %{
        ctx
        | conditions: ctx.conditions ++ [{:falsy, condition}],
          reload_deps: ctx.reload_deps ++ expr_deps(node.condition)
      },
      acc,
      resource
    )
  end

  defp event_walk(%{kind: :when} = node, addr, ctx, acc, resource) do
    event_walk(
      %{kind: :if, condition: node.condition, then: node.child, else: nil},
      addr,
      ctx,
      acc,
      resource
    )
  end

  # Child boundaries index too: a binding key crossing render(Child, input)
  # inside an each needs the child addr's enclosing each chain to bind item
  # keys, and its condition chain for reachability.
  defp event_walk(%{kind: :resource_component, resource: child} = node, addr, ctx, acc, resource)
       when is_atom(child) do
    acc =
      Map.put(acc, addr, %{
        child_boundary: true,
        eaches: ctx.eaches,
        conditions: ctx.conditions
      })

    node
    |> Map.get(:assigns, %{})
    |> Enum.sort_by(fn {name, _value} -> to_string(name) end)
    |> Enum.reduce(acc, fn {name, value}, inner_acc ->
      if fragment_value?(value) and child_input_used?(child, name) do
        event_walk(value, fragment_addr(addr, name), ctx, inner_acc, resource)
      else
        inner_acc
      end
    end)
  end

  defp event_walk(%{kind: :each} = node, addr, ctx, acc, resource) do
    each =
      %{
        items_eval: evaluator(node.items, resource),
        items_ir: expression_ir(node.items),
        as: node.as,
        index: node.index,
        key_eval: key_evaluator(node[:key], resource)
      }

    event_walk_children(
      List.wrap(node.child),
      addr <> "/*",
      %{
        ctx
        | eaches: ctx.eaches ++ [each],
          reload_deps: ctx.reload_deps ++ expr_deps(node.items)
      },
      acc,
      resource
    )
  end

  defp event_walk(_node, _addr, _ctx, acc, _resource), do: acc

  defp event_walk_children(children, addr, ctx, acc, resource) when is_list(children) do
    event_walk(children, addr, ctx, acc, resource)
  end

  defp event_walk_children(child, addr, ctx, acc, resource),
    do: event_walk([child], addr, ctx, acc, resource)

  @doc false
  # The :child slot at `addr`, wherever it lives — top level or referenced
  # by keyed-list item_slot_ids (child-in-each), recursively.
  def child_slot(%AshUi.Patch.Table{} = table, addr) do
    case slot_path(table, addr) do
      {:ok, %{kind: :child} = slot, _keyed_ancestors} -> slot
      _not_a_child -> nil
    end
  end

  @doc false
  # The slot at `addr` plus its enclosing keyed-list slots, outermost first.
  # Host adapters use this compile-derived path to invalidate the exact
  # keyed-comprehension entry after a nested child action.
  def slot_path(%AshUi.Patch.Table{} = table, addr),
    do: find_slot_path(table, root_slot_ids(table), addr, [])

  @doc false
  # The page-space boundary owned by a binding that crosses a store-backed
  # or embedded child. Hosts force this boundary after the child action because
  # the child row may change independently of fields on the page record.
  # Keyed ancestors carry exact entry markers so both live and fragment
  # hosts invalidate only the owning row.
  def dispatch_boundary(key, %AshUi.Patch.Table{} = table) when is_binary(key) do
    with components when length(components) > 2 <- String.split(key, "."),
         chain <- Enum.drop(components, -2),
         {item_keys, slot, keyed_ancestors} <- root_child_boundary(chain, table) do
      case keyed_ancestors do
        [] ->
          [Map.get(slot.meta, :owner_addr, slot.addr)]

        [outermost | _rest] ->
          entry_markers =
            keyed_ancestors
            |> Enum.zip(item_keys)
            |> Enum.map(fn {keyed, item_key} -> {:entry, keyed.addr, item_key} end)

          [outermost.addr | entry_markers]
      end
    else
      _none -> nil
    end
  end

  def dispatch_boundary(_key, _table), do: nil

  @doc false
  # Compile-derived state paths surrounding the dispatched element. Adapters
  # use these only when an action leaves root attributes unchanged but mutates
  # relationship truth as a side effect; the paths select the smallest view
  # load that can make that element current again.
  def dispatch_reload_paths(key, %AshUi.Patch.Table{} = table) when is_binary(key) do
    components = String.split(key, ".")

    with encoded_addr when is_binary(encoded_addr) <- Enum.at(components, -2),
         addr <- decode_addr_component(encoded_addr) do
      # Reload paths are frame-relative to the table that compiled them. Only
      # root-table paths name page state the host may Ash.load; a child
      # table's paths name the CHILD's own frame (an embedded row's
      # attributes, a store-backed child's fields) and must never reach the
      # page reloader — the dispatch owner write already returns that state,
      # and boundary invalidation re-renders the child subtree.
      case binding_target(table, key) do
        {:ok, %AshUi.Patch.Table{}, _chain} ->
          []

        :root ->
          table.event_elements
          |> Map.get(addr, %{})
          |> Map.get(:reload_paths, [])
      end
    else
      _missing -> []
    end
  end

  def dispatch_reload_paths(_key, _table), do: []

  @doc false
  # The deepest child table crossed by a binding and the runtime chain at
  # that child root. Fragment hosts use this to diff the action-owning child
  # directly while emitting ids/bindings in the parent page's DOM namespace.
  def binding_target(%AshUi.Patch.Table{} = table, key) when is_binary(key) do
    components = key |> String.split(".") |> Enum.drop(-1)

    {_table, _prefix, target} =
      Enum.reduce(components, {table, [], nil}, fn component, {table, prefix, target} ->
        prefix = prefix ++ [component]
        addr = decode_addr_component(component)

        case child_table(table, addr) do
          %AshUi.Patch.Table{} = child_table ->
            {child_table, prefix, {child_table, prefix}}

          _missing ->
            {table, prefix, target}
        end
      end)

    case target do
      {%AshUi.Patch.Table{} = child_table, chain} -> {:ok, child_table, chain}
      nil -> :root
    end
  end

  def binding_target(_table, _key), do: :root

  defp find_slot_path(table, ids, addr, keyed_ancestors) do
    Enum.find_value(ids, fn id ->
      slot = Map.fetch!(table.slots, id)

      case slot do
        %{addr: ^addr} = slot ->
          {:ok, slot, keyed_ancestors}

        %{kind: :keyed_list, addr: keyed_addr} = keyed_slot ->
          if String.starts_with?(addr, keyed_addr <> "/") do
            find_slot_path(
              table,
              item_slot_ids(keyed_slot),
              addr,
              keyed_ancestors ++ [keyed_slot]
            )
          end

        _other ->
          nil
      end
    end)
  end

  defp root_child_boundary(chain, table) do
    chain
    |> Enum.with_index()
    |> Enum.find_value(fn {component, index} ->
      addr = decode_addr_component(component)

      case slot_path(table, addr) do
        {:ok, %{kind: :child} = slot, keyed_ancestors} ->
          item_keys = Enum.take(chain, index)

          if length(item_keys) == length(keyed_ancestors) do
            {item_keys, slot, keyed_ancestors}
          end

        _other ->
          nil
      end
    end)
  end

  defp child_table(%AshUi.Patch.Table{} = table, addr) do
    Map.get(table.children, addr) ||
      case child_slot(table, addr) do
        %{meta: %{resource: resource}} when is_atom(resource) ->
          table(resource, target: table.target)

        _missing ->
          nil
      end
  end

  # ── slots / indexes ───────────────────────────────────────────────────────

  # Slots are built scope-by-scope because keyed-list item invalidation has a
  # different owner than root invalidation. Persist them once in a global
  # address store, retaining only lists of ids at the scope boundaries.
  # Branch-arm slots already participate in their enclosing scope, so their
  # metadata references those same entries instead of serializing a second
  # subtree map.
  defp flatten_slots(root_slots) do
    {slots, root_slot_ids} = flatten_slot_scope(root_slots, %{})
    {slots, root_slot_ids}
  end

  defp flatten_slot_scope(scope, all_slots) do
    Enum.reduce(scope, {all_slots, []}, fn {id, slot}, {all_slots, ids} ->
      {meta, all_slots} =
        Enum.reduce(
          [{:arm_slots, :arm_slot_ids}, {:item_slots, :item_slot_ids}],
          {slot.meta, all_slots},
          fn
            {source, target}, {meta, all_slots} ->
              case Map.pop(meta, source) do
                {subtree, meta} when is_map(subtree) ->
                  {all_slots, subtree_ids} = flatten_slot_scope(subtree, all_slots)
                  {Map.put(meta, target, subtree_ids), all_slots}

                {_missing, meta} ->
                  {meta, all_slots}
              end
          end
        )

      slot = %{slot | meta: meta}
      {Map.put(all_slots, id, slot), [id | ids]}
    end)
    |> then(fn {all_slots, ids} -> {all_slots, Enum.reverse(ids)} end)
  end

  defp root_slot_ids(%Table{root_slot_ids: nil, slots: slots}), do: Map.keys(slots)
  defp root_slot_ids(%Table{root_slot_ids: ids}), do: ids

  defp item_slot_ids(%{meta: %{item_slot_ids: ids}}) when is_list(ids), do: ids
  defp item_slot_ids(%{meta: %{item_slots: slots}}) when is_map(slots), do: Map.keys(slots)
  defp item_slot_ids(_slot), do: []

  defp put_slot(slots, addr, kind, deps, eval, meta) do
    deps = List.wrap(deps)
    id = {kind, addr, map_size(slots)}

    meta =
      meta
      |> Map.put(:dep_paths, state_dep_paths(deps))
      |> then(fn meta ->
        case item_dep_paths(deps) do
          [] -> meta
          paths -> Map.put(meta, :item_dep_paths, paths)
        end
      end)

    Map.put(slots, id, %{
      id: id,
      addr: addr,
      kind: kind,
      deps: deps |> Enum.map(&dep_root/1) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      errors?:
        Enum.any?(List.wrap(deps), &match?({:errors, _}, &1)) or
          Map.get(meta, :bound_fields, []) != [],
      eval: eval,
      meta: meta
    })
  end

  defp mark_child_error_surface(slots, addr, children) do
    case Map.get(children, addr) do
      %Table{error_slots: [_first | _rest]} ->
        Map.new(slots, fn
          {id, %{kind: :child, addr: ^addr} = slot} -> {id, %{slot | errors?: true}}
          slot -> slot
        end)

      _no_child_errors ->
        slots
    end
  end

  defp propagation(slots, resource) do
    slots
    |> Enum.flat_map(fn {id, slot} ->
      slot.deps
      |> Enum.flat_map(&propagation_fields(resource, &1, MapSet.new()))
      |> Enum.uniq()
      |> Enum.map(&{&1, id})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp propagation_addresses(propagation, slots) do
    Map.new(propagation, fn {field, ids} ->
      addresses =
        ids
        |> Enum.flat_map(fn id ->
          slot = Map.fetch!(slots, id)
          owner = Map.get(slot.meta, :owner_addr, slot.addr)
          if owner == slot.addr, do: [slot.addr], else: [owner, slot.addr]
        end)
        |> MapSet.new()

      {field, addresses}
    end)
  end

  defp propagation_fields(resource, field, seen)
       when is_atom(resource) and not is_nil(resource) and is_atom(field) do
    if MapSet.member?(seen, field) do
      [field]
    else
      seen = MapSet.put(seen, field)

      dependencies =
        with %{calculation: {Ash.Resource.Calculation.Expression, opts}} <-
               Ash.Resource.Info.calculation(resource, field),
             expression when not is_nil(expression) <- Keyword.get(opts, :expr) do
          expression
          |> Ash.Filter.list_refs()
          |> Enum.flat_map(fn
            %{relationship_path: [root | _rest]} when is_atom(root) -> [root]
            %{relationship_path: [], attribute: %{name: name}} when is_atom(name) -> [name]
            %{relationship_path: [], attribute: name} when is_atom(name) -> [name]
            _other -> []
          end)
          |> Enum.uniq()
        else
          _not_an_expression_calculation -> []
        end

      [field | Enum.flat_map(dependencies, &propagation_fields(resource, &1, seen))]
    end
  end

  defp propagation_fields(_resource, field, _seen), do: [field]

  # Slots that read dispatch-error state — authored errors()/field_errors()
  # reads plus attrs chunks of field-name-bound elements (automatic
  # distribution targets). The bridge re-renders exactly these when the
  # error state transitions. A slot authored in a RenderTree-valued child
  # input needs BOTH addresses: the owner boundary makes the nested Rendered
  # reachable, and the caller-owned slot address prevents the fragment from
  # returning nil under host change tracking.
  defp error_index(slots) do
    slots
    |> Enum.flat_map(fn
      {_id, %{kind: :keyed_list, errors?: true} = slot} ->
        [
          Map.get(slot.meta, :owner_addr, slot.addr),
          slot.addr,
          {:force_entries, slot.addr}
        ]

      {_id, %{errors?: true} = slot} ->
        [Map.get(slot.meta, :owner_addr, slot.addr), slot.addr]

      _other ->
        []
    end)
    |> Enum.uniq()
  end

  # The field names an element's bindings target (action_input literal
  # keys) — the bind-by-field-name contract makes these the distribution
  # addresses for field-path'd action errors.
  defp bound_field_names(node) do
    events = node |> Map.get(:events, []) |> List.wrap()

    case {events, Map.get(node, :attrs, %{})} do
      {[_ | _], attrs} when is_map(attrs) ->
        case Map.get(attrs, "name") || Map.get(attrs, :name) do
          name when is_atom(name) and not is_nil(name) ->
            [name]

          name when is_binary(name) and name != "" ->
            Enum.reject([safe_field_atom(name)], &is_nil/1)

          _unnamed ->
            events
            |> Enum.flat_map(fn binding ->
              case Map.get(binding, :args_exprs) do
                %{} = args -> Map.keys(args)
                _other -> []
              end
            end)
            |> Enum.uniq()
        end

      _no_events ->
        []
    end
  end

  defp safe_field_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp collection_index(slots) do
    for {id, %{kind: :keyed_list} = slot} <- slots,
        dep <- slot.deps,
        reduce: %{} do
      acc -> Map.update(acc, dep, [id], &[id | &1])
    end
  end

  # ── element attr chunk ────────────────────────────────────────────────────

  @doc """
  PATCH-ADDRESSABLE — the compile-time property that decides which elements
  a runtime patch can target, and therefore which elements carry a runtime
  id (morph selectors, reorder anchors, focus handles). An element is
  patch-addressable when

    * its attr surface is dynamic (`element_attr_deps/1` != `:static`) — an
      attribute patch selects the element itself, or
    * it DIRECTLY owns a non-element dynamic child (a text/branch/each/child
      slot) — those patches select the nearest enclosing element.

  Template and arm ROOTS are addressable by position (entry morphs and
  branch-flip morphs target them) and are marked by the skeleton pass, not
  by this predicate. Every other element — static wrappers and leaves — is
  NOT addressable and must not spend id bytes: at collection scale the
  per-element id was the single largest DOM/wire mass after binding keys,
  and every marked element forces its whole attr region dynamic.
  """
  @spec patch_addressable?(map()) :: boolean()
  def patch_addressable?(node) do
    element_attr_deps(node) != :static or
      Enum.any?(Map.get(node, :children, []), fn
        %{kind: :element} -> false
        %{kind: :text, content: %CompiledExpr{}} -> true
        %{kind: :text} -> false
        _dynamic_child -> true
      end)
  end

  @doc false
  # :static when nothing on the attr surface can change; otherwise the union
  # of expr deps across attrs, state conditions, part, and event payloads.
  def element_attr_deps(node) do
    attr_deps = node |> Map.get(:attrs, %{}) |> Map.values() |> Enum.flat_map(&expr_deps/1)

    state_deps =
      node |> Map.get(:states, []) |> List.wrap() |> Enum.flat_map(&expr_deps(Map.get(&1, :when)))

    part_deps = expr_deps(Map.get(node, :part))

    events = node |> Map.get(:events, []) |> List.wrap()

    event_deps = Enum.flat_map(events, &event_binding_deps/1)

    # Event payload deps deliberately EXCLUDED: the serialized binding key
    # does not change with payload values (payloads evaluate at dispatch),
    # so they must not invalidate the chunk.
    _ = event_deps
    deps = attr_deps ++ state_deps ++ part_deps

    cond do
      deps != [] -> Enum.uniq(deps)
      events != [] -> []
      dynamic_attr_surface?(node) -> []
      true -> :static
    end
  end

  # Part names and ordinary meta are STATIC paint hooks — they bake into
  # the skeleton via the sentinel oracle and must never taint the attr
  # surface dynamic (measured: doing so made 10k-row diffs larger than the
  # full HTML). Only genuinely runtime inputs count.
  defp dynamic_attr_surface?(node) do
    Map.get(node, :states, []) != [] or match?(%CompiledExpr{}, Map.get(node, :part))
  end

  defp event_binding_deps(%_{} = binding), do: binding |> Map.from_struct() |> binding_map_deps()
  defp event_binding_deps(%{} = binding), do: binding_map_deps(binding)
  defp event_binding_deps(_other), do: []

  defp binding_map_deps(binding) do
    binding
    |> Map.take([:args_exprs, :meta])
    |> Map.values()
    |> Enum.flat_map(&nested_expr_deps/1)
  end

  defp nested_expr_deps(%CompiledExpr{deps: deps}), do: deps

  defp nested_expr_deps(%{} = map) when not is_struct(map),
    do: Enum.flat_map(Map.values(map), &nested_expr_deps/1)

  defp nested_expr_deps(list) when is_list(list), do: Enum.flat_map(list, &nested_expr_deps/1)
  defp nested_expr_deps(_other), do: []

  @doc false
  # Evaluator for the whole attr chunk: materialize JUST this element via
  # the ordinary render pipeline (children stripped, view swapped for the
  # single element) and serialize its attributes through the same HTML
  # path the full render uses. Binding keys embed the child/item chain
  # from the scope (`:__bp_binding_chain__` in context) plus this
  # element's stable lowered address — decodable with zero registration.
  def element_attrs_evaluator(
        node,
        resource,
        addr,
        target \\ AshUi.RenderTarget.Static
      ) do
    element = node |> Map.put(:children, []) |> Map.put(:__bp_addr__, addr)
    addr_component = addr_component(addr)
    compiled = AshUi.Runtime.ResourceInfo.compiled_resource(resource)

    static_opts =
      [
        action_client_actions_by_part:
          AshUi.Runtime.ViewRender.action_client_actions_by_part(compiled)
      ]
      |> AshUi.Runtime.ViewRender.put_grouped_client_opts()

    descriptor = %{
      element: element,
      resource: resource,
      static_opts: static_opts,
      addr_component: addr_component,
      target: target
    }

    descriptor =
      case dynamic_attr_template(
             element,
             resource,
             compiled,
             static_opts,
             addr_component,
             target
           ) do
        {:ok, dynamic_attr_template} ->
          # Per-row constants of the piece-split Rendered, computed ONCE at
          # template compile: the statics list and fingerprint depend only on
          # the piece count and address, never on row values.
          pieces =
            length(dynamic_attr_template.dynamic_attr_parts) +
              length(dynamic_attr_template.dynamic_attrs)

          descriptor
          |> Map.merge(dynamic_attr_template)
          |> Map.merge(%{
            piece_statics: List.duplicate("", pieces + 1),
            piece_fingerprint: :erlang.phash2({:bp_attr_split, addr, pieces})
          })

        :error ->
          if static_event_attrs?(element, compiled) do
            marker = "BPBINDINGSENTINEL"
            marker_prefix = marker <> "." <> addr_component

            template_element =
              Map.update!(element, :events, fn events ->
                Enum.map(events, &%{&1 | args_exprs: %{}})
              end)

            template_scope =
              AshUi.Expr.Scope.new(struct(resource), %{}, ash_resource_module: resource)

            template =
              render_element_attrs(
                template_element,
                compiled,
                static_opts,
                template_scope,
                [marker],
                addr_component,
                target
              )

            Map.put(
              descriptor,
              :template_parts,
              :binary.split(template, marker_prefix, [:global])
            )
          else
            descriptor
          end
      end

    {:element_attrs, descriptor}
  end

  @doc false
  # The attrs chunk split into separately shippable pieces for the
  # differential renderer: `parts` are the serialized attribute segments
  # BETWEEN dynamic attrs (static per entry — binding keys, aria, titles),
  # `pairs` are the expr-valued attribute pairs themselves, tagged with the
  # attr name so the renderer can gate each one on its own `addr@name`
  # changed address. Only available for template-specialized descriptors on
  # the happy path; `:error` falls back to the whole-chunk evaluator.
  def evaluate_element_attr_pieces(
        %{dynamic_attrs: dynamic_attrs, dynamic_attr_parts: template_parts} = descriptor,
        scope
      )
      when scope.errors in [nil, []] do
    chain = Map.get(scope.context, :__bp_binding_chain__, [])
    runtime_prefix = Enum.join(chain ++ [descriptor.addr_component], ".")

    parts =
      Enum.map(template_parts, fn part ->
        part |> insert_marker(runtime_prefix) |> IO.iodata_to_binary()
      end)

    pairs =
      Enum.map(dynamic_attrs, fn
        %{runtime_id?: true, address: address} = dynamic_attr ->
          value = descriptor.target.dom_id(address, chain)

          {:stable,
           AshUi.RenderTarget.Html.dynamic_attribute_iodata(
             attr_name_string(dynamic_attr),
             dynamic_attr.target_name,
             value
           )
           |> IO.iodata_to_binary()}

        dynamic_attr ->
          value = Evaluator.eval(dynamic_attr.eval, scope)
          name = attr_name_string(dynamic_attr)

          {name,
           AshUi.RenderTarget.Html.dynamic_attribute_iodata(
             name,
             dynamic_attr.target_name,
             value
           )
           |> IO.iodata_to_binary()}
      end)

    {:ok, parts, pairs}
  end

  def evaluate_element_attr_pieces(_descriptor, _scope), do: :error

  # Precomputed at template compile; the fallback covers descriptors
  # persisted by pages compiled against the previous shape.
  defp attr_name_string(%{original_name_string: name}), do: name
  defp attr_name_string(%{original_name: name}), do: to_string(name)

  @doc false
  def evaluate_element_attrs(descriptor, scope) when is_map(descriptor) do
    chain = Map.get(scope.context, :__bp_binding_chain__, [])

    case descriptor do
      %{dynamic_attrs: dynamic_attrs, dynamic_attr_parts: parts}
      when scope.errors in [nil, []] ->
        runtime_prefix = Enum.join(chain ++ [descriptor.addr_component], ".")

        pairs =
          Enum.map(dynamic_attrs, fn dynamic_attr ->
            value =
              case dynamic_attr do
                %{runtime_id?: true, address: address} ->
                  descriptor.target.dom_id(address, chain)

                dynamic_attr ->
                  Evaluator.eval(dynamic_attr.eval, scope)
              end

            AshUi.RenderTarget.Html.dynamic_attribute_iodata(
              to_string(dynamic_attr.original_name),
              dynamic_attr.target_name,
              value
            )
          end)

        parts
        |> Enum.map(&insert_marker(&1, runtime_prefix))
        |> interleave_attr_pairs(pairs)
        |> IO.iodata_to_binary()

      %{dynamic_attr: dynamic_attr} when scope.errors in [nil, []] ->
        runtime_prefix = Enum.join(chain ++ [descriptor.addr_component], ".")
        value = Evaluator.eval(dynamic_attr.eval, scope)

        pair =
          AshUi.RenderTarget.Html.dynamic_attribute_iodata(
            dynamic_attr.original_name,
            dynamic_attr.target_name,
            value
          )

        IO.iodata_to_binary([
          insert_marker(dynamic_attr.prefix_parts, runtime_prefix),
          pair,
          insert_marker(dynamic_attr.suffix_parts, runtime_prefix)
        ])

      %{template_parts: template_parts} when scope.errors in [nil, []] ->
        runtime_prefix = Enum.join(chain ++ [descriptor.addr_component], ".")
        template_parts |> insert_marker(runtime_prefix) |> IO.iodata_to_binary()

      descriptor ->
        compiled =
          case descriptor do
            %{resource: resource} when is_atom(resource) ->
              AshUi.Runtime.ResourceInfo.compiled_resource(resource)

            # Rolling recompiles may still hold an old cached table.
            %{compiled: compiled} ->
              compiled
          end

        render_element_attrs(
          descriptor.element,
          compiled,
          descriptor.static_opts,
          scope,
          chain,
          descriptor.addr_component,
          descriptor.target
        )
    end
  end

  defp dynamic_attr_template(element, resource, compiled, static_opts, addr_component, target) do
    runtime_id? = Map.get(element, :__bp_runtime_attrs__, false)

    dynamic_attrs =
      Enum.filter(Map.get(element, :attrs, %{}), fn
        {_name, %CompiledExpr{}} -> true
        _attr -> false
      end)

    with true <- runtime_id? or dynamic_attrs != [],
         [] <- Map.get(element, :states, []),
         false <- match?(%CompiledExpr{}, Map.get(element, :part)),
         false <-
           element.attrs
           |> Map.drop(Enum.map(dynamic_attrs, &elem(&1, 0)))
           |> contains_compiled_expr?(),
         %{} = actions <-
           AshUi.Runtime.ViewRender.action_client_actions_by_part(compiled),
         true <- actions == %{} do
      binding_marker = "BPBINDINGSENTINEL"
      marker_prefix = binding_marker <> "." <> addr_component

      replacements =
        dynamic_attrs
        |> Enum.with_index()
        |> Enum.map(fn {{name, expression}, index} ->
          marker = "BPATTRVALUESENTINEL#{index}X#{:erlang.phash2({addr_component, name})}"

          %{
            eval: Evaluator.compile(expression, resource),
            marker: marker,
            original_name: name,
            original_name_string: to_string(name),
            target_name: target.attr_name(name)
          }
        end)

      replacements =
        if runtime_id? do
          [
            %{
              address: Map.fetch!(element, :__bp_addr__),
              marker: "BPRUNTIMEIDSENTINEL#{:erlang.phash2(addr_component)}",
              original_name: "id",
              original_name_string: "id",
              runtime_id?: true,
              target_name: target.attr_name("id")
            }
            | replacements
          ]
        else
          replacements
        end

      template_element =
        element
        |> Map.update!(:attrs, fn attrs ->
          Enum.reduce(replacements, attrs, fn replacement, attrs ->
            Map.put(attrs, replacement.original_name, replacement.marker)
          end)
        end)
        |> Map.update!(:events, fn events -> Enum.map(events, &%{&1 | args_exprs: %{}}) end)

      template_scope =
        AshUi.Expr.Scope.new(struct(resource), %{}, ash_resource_module: resource)

      template =
        render_element_attrs(
          template_element,
          compiled,
          static_opts,
          template_scope,
          [binding_marker],
          addr_component,
          target
        )

      located =
        Enum.map(replacements, fn replacement ->
          pair =
            [{replacement.target_name, replacement.marker}]
            |> AshUi.RenderTarget.Html.attributes_iodata()
            |> IO.iodata_to_binary()

          case :binary.matches(template, pair) do
            [{start, length}] -> {:ok, start, length, replacement}
            _not_one_pair -> :error
          end
        end)

      if Enum.all?(located, &match?({:ok, _, _, _}, &1)) do
        located = Enum.sort_by(located, &elem(&1, 1))

        {parts, ordered, cursor} =
          Enum.reduce(located, {[], [], 0}, fn {:ok, start, length, replacement},
                                               {parts, ordered, cursor} ->
            part = binary_part(template, cursor, start - cursor)
            {[part | parts], [Map.delete(replacement, :marker) | ordered], start + length}
          end)

        parts =
          parts
          |> Enum.reverse()
          |> Kernel.++([binary_part(template, cursor, byte_size(template) - cursor)])
          |> Enum.map(&:binary.split(&1, marker_prefix, [:global]))

        {:ok, %{dynamic_attrs: Enum.reverse(ordered), dynamic_attr_parts: parts}}
      else
        :error
      end
    else
      _not_specializable -> :error
    end
  end

  defp interleave_attr_pairs([part | parts], pairs) do
    Enum.zip_with(pairs, parts, fn pair, part -> [pair, part] end)
    |> then(&[part | &1])
  end

  defp insert_marker([part], _marker), do: part
  defp insert_marker([first, second], marker), do: [first, marker, second]

  defp insert_marker([first, second, third], marker),
    do: [first, marker, second, marker, third]

  defp insert_marker([first, second, third, fourth], marker),
    do: [first, marker, second, marker, third, marker, fourth]

  defp insert_marker(parts, marker), do: Enum.intersperse(parts, marker)

  defp static_event_attrs?(element, compiled) do
    Map.get(element, :events, []) != [] and
      not Map.get(element, :__bp_runtime_attrs__, false) and
      Map.get(element, :states, []) == [] and
      not match?(%CompiledExpr{}, Map.get(element, :part)) and
      not contains_compiled_expr?(Map.get(element, :attrs, %{})) and
      AshUi.Runtime.ViewRender.action_client_actions_by_part(compiled) == %{}
  end

  defp contains_compiled_expr?(%CompiledExpr{}), do: true

  defp contains_compiled_expr?(%{} = value) do
    value
    |> Map.values()
    |> Enum.any?(&contains_compiled_expr?/1)
  end

  defp contains_compiled_expr?(value) when is_list(value),
    do: Enum.any?(value, &contains_compiled_expr?/1)

  defp contains_compiled_expr?(_value), do: false

  defp render_element_attrs(
         element,
         compiled,
         static_opts,
         scope,
         chain,
         _addr_component,
         target
       ) do
    context = Map.put(scope.context, :__blueprint_resource__, compiled)

    render_opts =
      static_opts ++
        [
          expr_scope_base: scope,
          session_id: Map.get(scope.record, :session_id),
          item_bindings: scope.item_bindings,
          index_bindings: scope.index_bindings,
          actor: scope.actor,
          tenant: scope.tenant,
          context: context,
          errors: scope.errors,
          __bp_chain__: chain
        ]

    {:ok, rendered} =
      AshUi.Runtime.ViewRender.render_view_node(
        compiled,
        element,
        scope.record,
        scope.args,
        render_opts
      )

    {:ok, rendered} =
      AshUi.RenderTree.render(
        rendered,
        target: target
      )

    rendered
    |> AshUi.RenderTarget.Html.attrs(target: target)
    |> AshUi.RenderTarget.Html.attributes_iodata()
    |> IO.iodata_to_binary()
  end

  @doc false
  # Reversible, key-safe encoding of a lowered address: "v/2/0/*" -> "v-2-0-x".
  def addr_component(addr) do
    addr |> String.replace("/", "-") |> String.replace("*", "x")
  end

  @doc false
  def decode_addr_component(component) when is_binary(component) do
    component |> String.replace("-", "/") |> String.replace("x", "*")
  end

  # ── expression helpers ────────────────────────────────────────────────────

  defp evaluator(value, resource), do: Evaluator.compile(value, resource)

  defp assigns_evaluator(assigns, resource, target) do
    evaluators =
      Map.new(assigns, fn
        {key, %CompiledExpr{} = expr} ->
          {key, evaluator(expr, resource)}

        {key, value} when is_map(value) ->
          if fragment_value?(value) do
            {key, {:fragment, value}}
          else
            {key, evaluator(value, resource)}
          end

        {key, static} ->
          {key, evaluator(static, resource)}
      end)

    {:assigns, resource, target, evaluators}
  end

  defp component_input_evaluator(%{record: record}, resource, _target),
    do: evaluator(record, resource)

  defp component_input_evaluator(%{assigns: assigns}, resource, target),
    do: assigns_evaluator(assigns, resource, target)

  defp expression_ir(%CompiledExpr{ir: ir}), do: ir
  defp expression_ir(other), do: other

  # Every CompiledExpr dep in a template subtree, item refs included
  # (slot deps drop them — they resolve per entry at runtime).
  defp collect_compiled_deps(%CompiledExpr{deps: deps}), do: deps

  defp collect_compiled_deps(%_{} = struct),
    do: struct |> Map.from_struct() |> Map.values() |> Enum.flat_map(&collect_compiled_deps/1)

  defp collect_compiled_deps(map) when is_map(map),
    do: map |> Map.values() |> Enum.flat_map(&collect_compiled_deps/1)

  defp collect_compiled_deps(list) when is_list(list),
    do: Enum.flat_map(list, &collect_compiled_deps/1)

  defp collect_compiled_deps(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.flat_map(&collect_compiled_deps/1)

  defp collect_compiled_deps(_other), do: []

  # The item fields the row template RENDERS: direct item-field refs plus,
  # for the render(Child, item) idiom, the child view's state fields and
  # primary key. nil = a whole-item read we cannot narrow (no projection).
  @doc false
  def keyed_item_deps(node) do
    as = node.as

    deps = node.child |> List.wrap() |> Enum.flat_map(&collect_compiled_deps/1)

    fields =
      Enum.flat_map(deps, fn
        {:item, [^as, [field | _rest]]} when is_atom(field) -> [field]
        _other -> []
      end)

    whole_refs =
      Enum.any?(deps, fn
        {:item, [^as, []]} -> true
        _other -> false
      end)

    child_fields =
      if whole_refs do
        node.child
        |> List.wrap()
        |> Enum.flat_map(fn
          %{kind: :resource_component, resource: child} when is_atom(child) ->
            case AshUi.Compiled.view_exprs(child) do
              %{view: %CompiledExpr{deps: child_deps}} ->
                state_fields =
                  Enum.flat_map(child_deps, fn
                    {:state, field} when is_atom(field) -> [field]
                    {:state, [field]} when is_atom(field) -> [field]
                    {:state, [field | _]} when is_atom(field) -> [field]
                    _other -> []
                  end)

                state_fields ++ Ash.Resource.Info.primary_key(child)

              _other ->
                [:__whole_item__]
            end

          _other ->
            []
        end)
      else
        []
      end

    cond do
      whole_refs and (child_fields == [] or :__whole_item__ in child_fields) -> nil
      true -> Enum.uniq(fields ++ child_fields)
    end
  rescue
    # broad rescue: child view introspection may raise for uncompiled or
    # non-blueprint modules — nil disables projection, which is correct
    _any -> nil
  end

  @doc false
  def annotate_screen_navigation(nodes, routes) when is_list(nodes),
    do: Enum.map(nodes, &annotate_screen_navigation(&1, routes))

  def annotate_screen_navigation(%{kind: :element} = node, routes) do
    node =
      if get_in(node, [:meta, :screen_navigation?]) do
        update_in(node, [:meta], fn meta ->
          meta
          |> Map.put(:screen_navigation_routes, routes.all)
          |> Map.put(:screen_navigation_patch_routes, routes.patch)
        end)
      else
        node
      end

    Map.update(node, :children, [], &annotate_screen_navigation(&1, routes))
  end

  def annotate_screen_navigation(%{kind: :resource_component} = node, routes) do
    node
    |> Map.put(:__bp_screen_navigation_routes__, routes)
    |> Map.update(:assigns, %{}, fn assigns ->
      Map.new(assigns, fn {name, value} ->
        {name, annotate_screen_navigation(value, routes)}
      end)
    end)
  end

  def annotate_screen_navigation(%{kind: _kind} = node, routes) do
    Enum.reduce([:children, :child, :then, :else], node, fn key, node ->
      if Map.has_key?(node, key) do
        Map.update!(node, key, &annotate_screen_navigation(&1, routes))
      else
        node
      end
    end)
  end

  def annotate_screen_navigation(other, _routes), do: other

  defp expr_deps(%CompiledExpr{deps: deps}), do: deps
  defp expr_deps(_static), do: []

  defp input_value_deps(value) do
    if fragment_value?(value), do: subtree_deps(value), else: expr_deps(value)
  end

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

  defp fragment_addr(addr, name), do: addr <> "/a" <> to_string(name)

  # A fragment hosting event-bound elements (or errors() reads) is an
  # error-distribution surface: the owning child boundary re-renders on
  # error transitions so the controls inside light up.
  defp subtree_error_surface?(%{kind: :element} = node) do
    bound_field_names(node) != [] or
      Enum.any?(List.wrap(Map.get(node, :children, [])), &subtree_error_surface?/1)
  end

  defp subtree_error_surface?(%{kind: :resource_component} = node) do
    node
    |> Map.get(:assigns, %{})
    |> Map.values()
    |> Enum.any?(fn value -> fragment_value?(value) and subtree_error_surface?(value) end)
  end

  defp subtree_error_surface?(%{} = node) do
    [:children, :child, :then, :else]
    |> Enum.flat_map(&List.wrap(Map.get(node, &1)))
    |> Enum.any?(&subtree_error_surface?/1)
  end

  defp subtree_error_surface?(list) when is_list(list),
    do: Enum.any?(list, &subtree_error_surface?/1)

  defp subtree_error_surface?(_other), do: false

  defp child_input_used?(child, name) do
    child
    |> AshUi.Compiled.view_exprs()
    |> Map.get(:view)
    |> case do
      nil ->
        false

      _expr ->
        child
        |> AshUi.Compiled.resource!()
        |> Map.fetch!(:view)
        |> collect_exprs()
        |> Enum.any?(fn %CompiledExpr{deps: deps} ->
          Enum.any?(deps, fn
            {:state, [^name | _rest]} -> true
            {:state, ^name} -> true
            _other -> false
          end)
        end)
    end
  end

  @doc false
  # State-rooted deps of a lowered subtree — the parent record fields an
  # item/arm template reads.
  def subtree_state_deps(node), do: node |> subtree_deps() |> Enum.uniq()

  defp subtree_deps(nil), do: []

  defp subtree_deps(node) when is_map(node) do
    {slots, _children} =
      walk(
        node,
        "d",
        %{},
        %{},
        nil,
        MapSet.new(),
        AshUi.RenderTarget.Static,
        {[], false}
      )

    slots |> Map.values() |> Enum.flat_map(& &1.deps)
  end

  defp subtree_deps(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &subtree_deps/1)
  defp subtree_deps(_other), do: []

  # Compiled expr deps arrive as tagged paths: [state: [:title]],
  # [state: [:folds]], item/arg tags for scoped refs. Root propagation keys
  # on the record field (the head of a :state path); non-state tags don't
  # invalidate from record changes.
  defp dep_root({:state, [[], root | _rest]}) when is_atom(root), do: root
  defp dep_root({:state, [root | _rest]}) when is_atom(root), do: root
  defp dep_root({:state, root}) when is_atom(root), do: root
  defp dep_root(dep) when is_atom(dep), do: dep
  defp dep_root(_other), do: nil

  defp state_dep_paths(deps) do
    deps
    |> Enum.flat_map(fn
      {:state, [[], root | rest]} when is_atom(root) -> [[root | rest]]
      {:state, [root | rest]} when is_atom(root) -> [[root | rest]]
      {:state, root} when is_atom(root) -> [[root]]
      root when is_atom(root) -> [[root]]
      _other -> []
    end)
    |> Enum.uniq()
  end

  defp item_dep_paths(deps) do
    deps
    |> Enum.flat_map(fn
      {:item, [binding, [field | rest]]} when is_atom(binding) and is_atom(field) ->
        [{binding, [field | rest]}]

      _other ->
        []
    end)
    |> Enum.uniq()
  end

  defp blueprint_view?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0) and
      map_size(AshUi.Compiled.view_exprs(module)) > 0
  end
end
