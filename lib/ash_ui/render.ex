defmodule AshUi.Render do
  @moduledoc """
  Builds `%AshUi.Rendered{}` structures straight from a compiled
  patch table — statics from the table's skeleton, dynamics from evaluator
  closures over the CURRENT record. The neutral differential contract uses
  nil-based change tracking: a dynamic whose address is not in the
  changed set (`AshUi.Patch.Runtime.changed_addresses/3`) returns
  `nil`, and the `AshUi.Diff` kernel decides the minimal keyed patch.
  This is the ONE runtime emission path —
  transports convert or diff its output, never re-emit.

  Keyed lists use the core render algebra's keyed comprehensions. Entry keys implement
  Ash resource identity (`AshUi.Patch.Keys` — authored `key:`
  expression, else the FULL primary key). Entry vars carry the item, the
  ordinal position when the template declares an index, and the parent
  record fields the item template reads (`:__parent__`) — the kernel's
  retained-variable comparison invalidates exactly the rows a move, item change,
  or parent-field change touches.

  Event binding keys thread through scopes as `:__bp_binding_chain__` in
  scope context: item boundaries append the entry key component, child
  boundaries append the child address component — producing exactly the
  keys `AshUi.Patch.Bindings.resolve/3` accepts.
  """

  alias AshUi.EventBinding
  alias AshUi.Expr.Scope
  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Evaluator
  alias AshUi.Patch.Keys
  alias AshUi.Patch.Runtime
  alias AshUi.Patch.Skeleton
  alias AshUi.Patch.Table
  alias AshUi.Comprehension
  alias AshUi.Rendered

  @doc """
  Build the root `Rendered` for `record` from its resource's patch table.

  `changed` is `:all` (mount / unknown before-image) or the address set
  from `AshUi.Patch.Runtime.changed_addresses/3`.

  Options: `:actor`, `:tenant`, `:params` (scope inputs — the staged
  evaluation of the view calculation runs under the same scope the
  calculation would), `:view`.
  """
  @spec build(struct(), :all | MapSet.t(), keyword()) :: Rendered.t() | struct()
  def build(%resource{} = record, changed, opts \\ []) do
    # ONE compiled artifact per render tree: the table threads through
    # every nested emission (children come from table.children) — nothing
    # recompiles mid-render. Hosts cache the table across renders.
    view = Keyword.get(opts, :view, :view)
    target = Keyword.get(opts, :target, AshUi.RenderTarget.Html)

    table =
      case Keyword.get(opts, :table) do
        %Table{target: ^target} = table -> table
        _other -> Compiler.table(resource, view, target: target)
      end

    # internal option threading is a MAP: emission touches options per
    # dynamic slot, and keyword lookups/puts dominate profiles at 10k rows
    # (reverse first: Map.new keeps the LAST duplicate, Keyword.get the first)
    opts =
      opts
      |> Enum.reverse()
      |> Map.new()
      |> Map.put(:table, table)
      |> Map.put(:target, target)
      |> Map.put_new(:session_id, Map.get(record, :session_id))
      # transports may inject their own struct names for the SAME algebra
      # (identical field sets by frozen contract) — construction cost is a
      # struct literal either way, so adapters pay zero conversion
      |> Map.put_new(:rendered_module, Rendered)
      |> Map.put_new(:comprehension_module, Comprehension)
      |> Map.put(:entry_children, %{})
      |> Map.put(:entry_parent_records, nil)
      |> Map.put(:entry_child_opts, nil)

    skeleton_rendered(table.skeleton, scope(resource, record, opts), changed, opts)
  end

  # ── skeleton → Rendered ────────────────────────────────────────────────────

  defp skeleton_rendered(%Skeleton{} = skeleton, scope, changed, opts) do
    # :changed is constant for the whole skeleton: put once, not per dynamic.
    # :attr_narrow gates individual attribute pairs inside attrs-chunk
    # Rendereds — authoritative only when this subtree renders against a real
    # changed set; an `:all` render (mount, branch arm) must emit every pair.
    emit_opts =
      case changed do
        %MapSet{} -> opts |> Map.put(:changed, changed) |> Map.put(:attr_narrow, changed)
        _all -> opts |> Map.put(:changed, changed) |> Map.delete(:attr_narrow)
      end

    dynamic =
      if Map.get(opts, :eager?, false) do
        # Initial materialization consumes every dynamic several times (diff,
        # HTML, keyed snapshot). Build the compiled skeleton's values once,
        # directly, instead of first retaining a page of scope-heavy lazy
        # closures and then allocating a second memoized page beside it.
        dynamics =
          Enum.map(skeleton.dynamics, &dyn(&1, scope, changed, false, emit_opts))

        fn _track_changes? -> dynamics end
      else
        fn track_changes? ->
          Enum.map(skeleton.dynamics, &dyn(&1, scope, changed, track_changes?, emit_opts))
        end
      end

    %{
      __struct__: Map.fetch!(opts, :rendered_module),
      static: skeleton.statics,
      dynamic: dynamic,
      fingerprint: skeleton.fingerprint,
      # Every independently diffed single-root skeleton participates in
      # LiveView's native magic-id/PHX_SKIP tracking. Skeleton compilation is
      # the structural authority: fragments and multi-root shapes stay false.
      root: skeleton.root?,
      caller: :not_available
    }
  end

  defp dyn(ref, scope, changed, track_changes?, emit_opts) do
    if track_changes? and skip?(ref, changed, emit_opts) do
      nil
    else
      emit(ref, scope, emit_opts)
    end
  end

  defp skip?(_ref, changed, _opts) when changed == :all, do: false

  defp skip?(ref, _changed, %{fragment_inputs_only?: true}) do
    not fragment_input_dynamic?(ref)
  end

  # Arm slots are first-class table slots registered under the branch's
  # address prefix, so a content change inside an arm names an `addr/t|f/...`
  # address, not the branch itself. Descend whenever the changed set names
  # the branch OR anything under it; the arm emission then gates its own
  # dynamics by the same set. Changed sets are O(changed) small, so the
  # prefix scan is cheap.
  defp skip?({:branch, addr, _condition, _arms}, changed, _opts) do
    prefix = addr <> "/"

    not (MapSet.member?(changed, addr) or
           Enum.any?(changed, fn
             member when is_binary(member) -> String.starts_with?(member, prefix)
             _marker -> false
           end))
  end

  defp skip?(ref, changed, _opts), do: not MapSet.member?(changed, elem(ref, 1))

  defp fragment_input_dynamic?({:fragment_input, _addr, _parent_resource, _skeleton}), do: true

  defp fragment_input_dynamic?({:branch, _addr, _condition, arms}) do
    skeleton_has_fragment_input?(arms.true) or skeleton_has_fragment_input?(arms.false)
  end

  defp fragment_input_dynamic?({:keyed, _addr, _items, item}),
    do: skeleton_has_fragment_input?(item.skeleton)

  defp fragment_input_dynamic?(_dynamic), do: false

  defp skeleton_has_fragment_input?(nil), do: false

  defp skeleton_has_fragment_input?(%Skeleton{dynamics: dynamics}),
    do: Enum.any?(dynamics, &fragment_input_dynamic?/1)

  defp emit({:text, _addr, eval}, scope, opts) do
    value = Evaluator.eval(eval, scope)

    if AshUi.RenderTarget.Html.render_tree_value?(value) do
      {:safe, iodata} =
        AshUi.RenderTarget.Html.render_static(value, target: Map.fetch!(opts, :target))

      iodata
    else
      value
      |> AshUi.RenderTarget.Html.text_content()
      |> AshUi.RenderTarget.Html.safe_to_iodata()
    end
  end

  # Template-specialized attrs chunk: emit as a nested Rendered whose
  # dynamics are the serialized segments — static parts (binding keys, aria,
  # titles; constant per entry) and one pair per expr-valued attribute. On a
  # differential render the parts vars-diff away (nil) and each pair gates on
  # its own `addr@name` changed address, so a composer keystroke ships the
  # `value`/`data-empty` pairs alone, never the element's whole attribute
  # region. Concatenated bytes are identical to the legacy single-chunk
  # string by construction. When errors are in scope the whole chunk renders
  # through the ordinary evaluator under a distinct fingerprint, so error
  # transitions swap the region wholesale — no mixed piece state.
  defp emit(
         {:attrs, addr,
          {:element_attrs, %{dynamic_attrs: _, dynamic_attr_parts: _} = descriptor} =
            eval},
         scope,
         opts
       ) do
    case AshUi.Patch.Compiler.evaluate_element_attr_pieces(descriptor, scope) do
      {:ok, parts, pairs} ->
        [first_part | rest_parts] = parts

        pieces =
          [
            {:stable, first_part}
            | Enum.zip_with(pairs, rest_parts, fn pair, part ->
                [pair, {:stable, part}]
              end)
              |> List.flatten()
          ]

        narrow = Map.get(opts, :attr_narrow)

        dynamic = fn track_changes? ->
          Enum.map(pieces, fn
            {:stable, value} ->
              if track_changes?, do: nil, else: value

            {name, value} ->
              cond do
                not track_changes? -> value
                is_nil(narrow) -> value
                MapSet.member?(narrow, addr <> "@" <> name) -> value
                true -> nil
              end
          end)
        end

        %{
          __struct__: Map.fetch!(opts, :rendered_module),
          static: Map.get(descriptor, :piece_statics) || List.duplicate("", length(pieces) + 1),
          dynamic: dynamic,
          fingerprint:
            Map.get(descriptor, :piece_fingerprint) ||
              :erlang.phash2({:bp_attr_split, addr, length(pieces)}),
          root: false,
          caller: :not_available
        }

      :error ->
        value = Evaluator.eval(eval, scope)

        %{
          __struct__: Map.fetch!(opts, :rendered_module),
          static: ["", ""],
          dynamic: fn _track_changes? -> [value] end,
          fingerprint: :erlang.phash2({:bp_attr_errors, addr}),
          root: false,
          caller: :not_available
        }
    end
  end

  defp emit({:attrs, _addr, eval}, scope, _opts), do: Evaluator.eval(eval, scope)

  defp emit({:computed, _addr, eval}, scope, opts) do
    # A computed subtree is a rendered fragment (coarse: re-renders whole
    # on dep change), NEVER escaped text.
    case Evaluator.eval(eval, scope) do
      nil ->
        ""

      value ->
        {:safe, iodata} =
          AshUi.RenderTarget.Html.render_static(value, target: Map.fetch!(opts, :target))

        iodata
    end
  end

  defp emit({:fragment_input, _addr, _parent_resource, skeleton}, _scope, opts) do
    %{scope: parent_scope, changed: changed, opts: parent_opts} =
      Map.fetch!(opts, :fragment_parent)

    skeleton_rendered(skeleton, parent_scope, changed, parent_opts)
  end

  defp emit({:branch, addr, cond_eval, arms}, scope, opts) do
    arm = if truthy?(Evaluator.eval(cond_eval, scope)), do: arms.true, else: arms.false

    case arm do
      nil ->
        ""

      %Skeleton{} = skeleton ->
        # Page-skeleton context: the branch's OWN address in the changed set
        # means the condition's inputs moved — the arm may have flipped, and
        # a flip must emit the arm whole (`:all`) so its fingerprint swaps
        # statics on the client. Otherwise the same arm is showing and its
        # content gates by the same changed set as flat content: arm slots
        # are first-class, so a keystroke inside an if/each shell re-emits
        # only the slots that read the field that moved.
        #
        # Inside a KEYED ENTRY re-render (entry_vars_changed present) the
        # page-level set does not speak for this row: the entry gate already
        # decided this branch re-emits, and row granularity means the taken
        # arm emits whole.
        arm_changed =
          case Map.get(opts, :changed, :all) do
            %MapSet{} = changed ->
              cond do
                Map.has_key?(opts, :entry_vars_changed) -> :all
                MapSet.member?(changed, addr) -> :all
                true -> changed
              end

            _all ->
              :all
          end

        skeleton_rendered(skeleton, scope, arm_changed, opts)
    end
  end

  defp emit({:keyed, addr, items_eval, item}, scope, opts) do
    items = items_eval |> Evaluator.eval(scope) |> List.wrap()
    parent = parent_vars(item, scope)
    key_fun = entry_key_fun(item, items)
    changed = Map.get(opts, :changed, :all)
    item_scope_template = item_scope_template(scope, item)
    dynamics = item.skeleton.dynamics
    dynamic_count = length(dynamics)
    item_deps = Map.get(item, :item_deps)
    index? = item.index not in [nil, item.as]
    parent? = parent != %{}

    # Which sub-slot addresses each parent field feeds — the compiled index
    # that lets a parent-only change (a composer keystroke) re-render ONLY the
    # slots reading the field that moved, instead of the whole row. Built
    # whenever the row reads parent fields, INCLUDING under `changed = :all`:
    # a branch arm always re-renders with `:all` (branch = coarse by design),
    # so an each nested in an if/case arm — messaging's conversation shape —
    # would otherwise never narrow. The entry closures do their own precise
    # gating from LiveView's `__parent__` vars, so the page-level changed
    # shape at emit time carries no information the index needs.
    parent_dep_index = if parent?, do: keyed_parent_dep_index(opts, addr), else: nil
    item_dep_index = keyed_item_dep_index(opts, addr, item.as)

    parent_records = [scope.record | Map.get(scope.context, :__bp_parent_records__, [])]

    entry_opts =
      opts
      |> put_entry_children(item.skeleton)
      |> Map.put(:parent_dep_index, parent_dep_index)
      |> Map.put(:item_dep_index, item_dep_index)
      |> Map.put(:entry_parent_records, parent_records)
      |> Map.put(:entry_child_opts, %{
        parent_record: scope.record,
        parent_records: parent_records,
        actor: Map.get(opts, :actor),
        tenant: Map.get(opts, :tenant),
        context: Map.get(opts, :context, %{}),
        session_id: Map.get(opts, :session_id),
        reuse_loaded_values?: Map.get(opts, :reuse_loaded_values?, false),
        child_record_cache_get: Map.get(opts, :child_record_cache_get),
        child_record_cache_put: Map.get(opts, :child_record_cache_put)
      })

    {entries, _next_index} =
      Enum.map_reduce(items, 0, fn entry, index ->
        entry_scope = item_scope(item_scope_template, entry, index)
        key = key_fun.(entry, index, entry_scope)
        key_component = EventBinding.key_component(key)
        force? = force_entry?(changed, addr, key_component)
        vars = entry_vars(entry, index, item_deps, index?, parent, parent?)

        rendered_entry =
          {key, vars,
           entry_render_fun(
             item.skeleton,
             dynamic_count,
             entry_scope,
             Map.fetch!(vars, :item),
             parent,
             key_component,
             force?,
             scope,
             entry_opts
           )}

        {rendered_entry, index + 1}
      end)

    {static, fingerprint} =
      if item.skeleton.root? do
        <<wrapper_fingerprint::128>> =
          :erlang.md5(
            :erlang.term_to_binary(
              {:ash_ui_rooted_keyed_comprehension, item.skeleton.fingerprint}
            )
          )

        {["", ""], wrapper_fingerprint}
      else
        {item.skeleton.statics, item.skeleton.fingerprint}
      end

    %{
      __struct__: Map.fetch!(opts, :comprehension_module),
      static: static,
      has_key?: true,
      entries: entries,
      fingerprint: fingerprint,
      stream: nil
    }
  end

  defp emit({:child, addr, resource, input_eval, embedded?}, scope, opts) do
    # Input evaluator + backing were resolved at compile time. Construction
    # still runs through the one ordinary Ash child boundary: embedded input
    # must cast/default/change exactly as semantic rendering does, while a
    # store-backed child resolves its mounted row.
    {child_table, error_record, addr_component, direct_fragment_inputs} =
      child_info(opts, addr, resource)

    input = Evaluator.eval_component_input(input_eval, scope, direct_fragment_inputs)

    parent_records =
      Map.get(opts, :entry_parent_records) ||
        [scope.record | Map.get(scope.context, :__bp_parent_records__, [])]

    record_result =
      case input do
        %{__struct__: ^resource} = record when embedded? ->
          # Embedded values held by a parent record already crossed their Ash
          # create/cast boundary. Preserve that identity directly on render;
          # constructing cache/boundary options only to rediscover the same
          # struct costs several maps for every keyed row on initial mount.
          {:ok, record}

        _other ->
          child_opts =
            Map.get(opts, :entry_child_opts) ||
              %{
                parent_record: scope.record,
                parent_records: parent_records,
                actor: Map.get(opts, :actor),
                tenant: Map.get(opts, :tenant),
                context: Map.get(opts, :context, %{}),
                session_id: Map.get(opts, :session_id),
                reuse_loaded_values?: Map.get(opts, :reuse_loaded_values?, false),
                child_record_cache_get: Map.get(opts, :child_record_cache_get),
                child_record_cache_put: Map.get(opts, :child_record_cache_put)
              }

          child_boundary =
            {resource,
             Map.get(scope.context, :__bp_binding_chain__, []) ++
               [addr_component]}

          child_opts = Map.put(child_opts, :child_record_cache_boundary, child_boundary)
          AshUi.build_child_record(resource, input, child_opts)
      end

    error_path =
      expression_path(error_record, Map.get(scope.context, :__bp_item_paths__, %{}))

    case record_result do
      {:ok, record} ->
        child_scope =
          resource
          |> child_scope(record, scope, error_path, parent_records, addr_component)

        child_render_opts =
          opts
          |> Map.put(:table, child_table)
          |> Map.put(:entry_children, %{})
          |> Map.put(:entry_parent_records, nil)
          |> Map.put(:entry_child_opts, nil)

        child_render_opts =
          if direct_fragment_inputs == [] do
            Map.delete(child_render_opts, :fragment_parent)
          else
            fragment_parent = %{
              scope: scope,
              changed: Map.get(opts, :changed, :all),
              opts:
                opts
                |> Map.delete(:fragment_parent)
            }

            Map.put(child_render_opts, :fragment_parent, fragment_parent)
          end

        fragment_inputs_only? =
          match?(%MapSet{}, Map.get(opts, :changed)) and
            MapSet.member?(Map.fetch!(opts, :changed), {:fragment_inputs, addr})

        child_changed =
          if fragment_inputs_only? do
            Map.fetch!(opts, :changed)
          else
            case precise_entry_child_changed(opts, child_table, record) do
              {:ok, changed} -> changed
              :error -> :all
            end
          end

        child_render_opts =
          Map.put(child_render_opts, :fragment_inputs_only?, fragment_inputs_only?)

        skeleton_rendered(
          child_table.skeleton,
          child_scope,
          child_changed,
          child_render_opts
        )

      {:error, error} ->
        # child-boundary degradation, identical in BOTH renderers: the page
        # survives and the ORIGINAL Ash error projects through the standard
        # error surface — never an invented message
        first = error |> AshUi.Runtime.Errors.list() |> List.first()

        message =
          case AshUi.Runtime.Errors.field(first) do
            nil -> AshUi.Runtime.Errors.message(first)
            field -> "#{field}: #{AshUi.Runtime.Errors.message(first)}"
          end

        %{
          __struct__: Map.fetch!(opts, :rendered_module),
          static: [
            ~s(<div data-ash-ui-error="invalid-child-input" role="alert">),
            "</div>"
          ],
          dynamic: fn _track_changes? ->
            [AshUi.RenderTarget.Html.safe_to_iodata(message)]
          end,
          fingerprint: :erlang.phash2({:invalid_child_input, resource}),
          root: true,
          caller: :not_available
        }
    end
  end

  # Identity derivation hoisted out of the row loop: authored key: gets its
  # scope per entry; Ash resources resolve pk FIELDS once per collection.
  defp entry_key_fun(%{key_eval: key_eval}, _items)
       when not is_nil(key_eval) do
    fn _entry, _index, entry_scope -> Evaluator.eval(key_eval, entry_scope) end
  end

  defp entry_key_fun(_item, [%resource{} | _]) do
    if Ash.Resource.Info.resource?(resource) do
      case Ash.Resource.Info.primary_key(resource) do
        [] ->
          fn _entry, index, _entry_scope -> index end

        [pk] ->
          fn entry, _index, _entry_scope -> Map.get(entry, pk) end

        pks ->
          fn entry, _index, _entry_scope ->
            pks |> Enum.map(&Map.get(entry, &1)) |> List.to_tuple()
          end
      end
    else
      fn entry, index, _entry_scope -> Keys.entry_key(entry, index) end
    end
  end

  defp entry_key_fun(_item, _items) do
    fn entry, index, _entry_scope -> Keys.entry_key(entry, index) end
  end

  # Direct struct build — Scope.new's keyword/context machinery costs more
  # than a small child render at scale.
  defp child_scope(resource, record, parent_scope, error_path, parent_records, addr_component) do
    all_errors =
      Map.get(parent_scope.context, :__bp_all_errors__, parent_scope.all_errors)

    errors =
      if all_errors == [], do: [], else: AshUi.errors_at_path(all_errors, error_path)

    chain = Map.get(parent_scope.context, :__bp_binding_chain__, [])

    %Scope{
      record: record,
      state: record,
      resource: resource,
      ash_resource_module: resource,
      helper_module: resource,
      actor: parent_scope.actor,
      tenant: parent_scope.tenant,
      errors: errors,
      all_errors: all_errors,
      args: %{},
      # the binding chain ACCUMULATES through nesting — a fresh context
      # here severed keys below the second crossing from the resolver's
      # address space (one key language)
      context:
        parent_scope.context
        |> Map.put(:__bp_parent_records__, parent_records)
        |> Map.put(:__bp_error_path__, error_path)
        |> Map.put(:__bp_binding_chain__, chain ++ [addr_component])
    }
  end

  # ── keyed entries ──────────────────────────────────────────────────────────

  # Entry vars are LiveView's change-tracking contract: the item, the
  # ordinal (when the template declares an index — a pure move must
  # invalidate index-dependent rows), and the parent fields the template
  # reads (a parent-only change must re-render the rows displaying it).
  defp entry_vars(entry, index, item_deps, index?, parent, parent?) do
    # change tracking sees only the fields the row template renders: an
    # unrendered field change (position bookkeeping) must not dirty rows
    projected =
      case item_deps do
        [_ | _] = fields when is_map(entry) -> Map.take(entry, fields)
        _unknown -> entry
      end

    case {index?, parent?} do
      {false, false} -> %{item: projected}
      {true, false} -> %{item: projected, __index__: index}
      {false, true} -> %{item: projected, __parent__: parent}
      {true, true} -> %{item: projected, __index__: index, __parent__: parent}
    end
  end

  defp parent_vars(%{parent_deps: [_ | _] = deps}, scope) do
    Map.new(deps, fn field -> {field, Map.get(scope.record, field)} end)
  end

  defp parent_vars(_item, _scope), do: %{}

  # LiveView passes vars_changed from comparing entry vars. New entries
  # render with track_changes? false; changed entries re-render whole (row
  # granularity — the same coarseness as branch arms). A single-root item is
  # returned as one nested Rendered dynamic so LiveView assigns a stable magic
  # id to the keyed entry. Pure index moves then carry that Rendered (and its
  # retained magic id) to the new index, allowing DOMPatch to splice the
  # existing node and PHX_SKIP its unchanged subtree. Multi-root item templates
  # retain the direct dynamics shape because no one DOM node can own the id.
  defp entry_render_fun(
         %Skeleton{} = skeleton,
         dynamic_count,
         entry_scope,
         current_item,
         current_parent,
         key_component,
         force?,
         parent_scope,
         opts
       ) do
    chain = Map.get(parent_scope.context, :__bp_binding_chain__, [])

    scope = %{
      entry_scope
      | context:
          Map.put(
            entry_scope.context,
            :__bp_binding_chain__,
            chain ++ [key_component]
          )
    }

    render_dynamics =
      if Map.get(opts, :eager?, false) do
        values = Enum.map(skeleton.dynamics, &emit(&1, scope, opts))
        fn _vars_changed, _track_changes? -> values end
      else
        fn vars_changed, track_changes? ->
          # The page-level attr_narrow set does not speak for THIS entry (a full
          # entry re-render must re-emit item-dependent attr pairs the page set
          # never names); only the parent-only narrow branch below re-establishes
          # one, from the parent-dep index.
          entry_opts =
            opts
            |> Map.put(:entry_vars_changed, vars_changed)
            |> Map.delete(:attr_narrow)

          cond do
            not track_changes? ->
              Enum.map(skeleton.dynamics, &emit(&1, scope, entry_opts))

            vars_changed == %{} and not force? ->
              List.duplicate(nil, dynamic_count)

            # A positional move can feed any index() expression, and an explicit
            # child-write marker has no before-image. Both therefore re-render
            # the entry whole.
            force? or Map.has_key?(vars_changed, :__index__) ->
              Enum.map(skeleton.dynamics, &emit(&1, scope, entry_opts))

            # Item and parent vars retain their before-images. The compiled
            # per-entry indexes map the fields that actually moved to nested slot
            # addresses, so a relationship change inside a keyed row descends to
            # that nested dynamic instead of declaring the row itself replaced.
            # Omitted sibling dynamics remain nil/unchanged all the way into the
            # native LiveView diff; they are never part of a partial row rebuild.
            true ->
              case entry_change_addresses(
                     vars_changed,
                     current_item,
                     current_parent,
                     opts
                   ) do
                :all ->
                  Enum.map(skeleton.dynamics, &emit(&1, scope, entry_opts))

                %MapSet{} = narrow ->
                  narrow_opts = Map.put(entry_opts, :attr_narrow, narrow)

                  Enum.map(skeleton.dynamics, fn ref ->
                    if dynamic_selected?(ref, narrow) do
                      emit(ref, scope, narrow_opts)
                    else
                      nil
                    end
                  end)
              end
          end
        end
      end

    if skeleton.root? do
      fn vars_changed, _track_changes? ->
        [
          %{
            __struct__: Map.fetch!(opts, :rendered_module),
            static: skeleton.statics,
            dynamic: fn track_changes? ->
              render_dynamics.(vars_changed, track_changes?)
            end,
            fingerprint: skeleton.fingerprint,
            root: true,
            caller: :not_available
          }
        ]
      end
    else
      render_dynamics
    end
  end

  defp entry_change_addresses(vars_changed, current_item, current_parent, opts) do
    Enum.reduce_while(vars_changed, MapSet.new(), fn
      {:item, changed_item}, addresses ->
        merge_changed_var_addresses(
          changed_item,
          current_item,
          Map.get(opts, :item_dep_index),
          addresses
        )

      {:__parent__, changed_parent}, addresses ->
        merge_changed_var_addresses(
          changed_parent,
          current_parent,
          Map.get(opts, :parent_dep_index),
          addresses
        )

      {_unknown_var, _change}, _addresses ->
        {:halt, :all}
    end)
  end

  defp merge_changed_var_addresses(_change, _current, nil, _addresses),
    do: {:halt, :all}

  defp merge_changed_var_addresses(change, current, index, addresses) do
    with {:ok, fields} <- changed_var_fields(change, current),
         {:ok, changed_addresses} <- addresses_for_fields(fields, index) do
      {:cont, MapSet.union(addresses, changed_addresses)}
    else
      :error -> {:halt, :all}
    end
  end

  defp changed_var_fields({:changed, %{} = old, %{} = new}, _current),
    do: {:ok, changed_field_names(new, old)}

  defp changed_var_fields(%{} = old, %{} = current),
    do: {:ok, changed_field_names(current, old)}

  defp changed_var_fields(_change, _current), do: :error

  defp addresses_for_fields(fields, index) do
    Enum.reduce_while(fields, {:ok, MapSet.new()}, fn field, {:ok, addresses} ->
      case Map.fetch(index, field) do
        {:ok, field_addresses} ->
          {:cont, {:ok, MapSet.union(addresses, field_addresses)}}

        # A changed record field that no compiled item slot reads is irrelevant
        # to this entry's render. This is common for persistence metadata such
        # as `updated_at`; widening it to the whole row defeats the dependency
        # index and turns an otherwise nested invalidation into a replacement.
        :error ->
          {:cont, {:ok, addresses}}
      end
    end)
  end

  defp changed_field_names(new, old) do
    added_or_changed = for {field, value} <- new, Map.get(old, field) != value, do: field
    removed = for {field, _value} <- old, not Map.has_key?(new, field), do: field
    added_or_changed ++ removed
  end

  defp dynamic_selected?({:branch, addr, _condition, _arms}, changed) do
    prefix = addr <> "/"

    MapSet.member?(changed, addr) or
      Enum.any?(changed, fn
        member when is_binary(member) -> String.starts_with?(member, prefix)
        _marker -> false
      end)
  end

  defp dynamic_selected?(ref, changed), do: MapSet.member?(changed, elem(ref, 1))

  # parent_field → MapSet of sub-slot addresses that read it, read from the
  # compiled keyed-list slot's item slots. Built once per keyed emit (not per
  # row); only the plain-atom field deps participate (item/positional deps are
  # tracked separately through the row vars). `nil` when this each's slot is not
  # found (the caller then re-renders the whole entry rather than narrowing).
  defp keyed_parent_dep_index(opts, addr) do
    with %Table{} = table <- Map.get(opts, :table),
         %{kind: :keyed_list} = slot <- find_keyed_slot(table, addr),
         item_slots when map_size(item_slots) > 0 <- Table.item_slots(table, slot) do
      Enum.reduce(item_slots, %{}, fn {_sid, slot}, index ->
        # A slot with an owner (a per-attribute `addr@name` sub-slot owned by
        # its element's attrs chunk) contributes BOTH addresses: the owner
        # keeps the chunk emitting, the sub-address gates the pair inside it.
        addrs =
          case Map.get(slot.meta, :owner_addr, slot.addr) do
            owner when owner == slot.addr -> [slot.addr]
            owner -> [owner, slot.addr]
          end

        Enum.reduce(slot.deps, index, fn
          dep, index when is_atom(dep) ->
            Map.update(index, dep, MapSet.new(addrs), fn set ->
              Enum.reduce(addrs, set, &MapSet.put(&2, &1))
            end)

          _non_field_dep, index ->
            index
        end)
      end)
    else
      _no_index -> nil
    end
  end

  # item_field -> the item-template slot addresses reading it. Item references
  # retain their binding/path in slot metadata even though root propagation
  # deliberately ignores them; this is the per-entry half of the compiled
  # propagation circuit.
  defp keyed_item_dep_index(opts, addr, binding) do
    with %Table{} = table <- Map.get(opts, :table),
         %{kind: :keyed_list} = slot <- find_keyed_slot(table, addr),
         item_slots when map_size(item_slots) > 0 <- Table.item_slots(table, slot) do
      Enum.reduce(item_slots, %{}, fn {_sid, slot}, index ->
        addrs =
          case Map.get(slot.meta, :owner_addr, slot.addr) do
            owner when owner == slot.addr -> [slot.addr]
            owner -> [owner, slot.addr]
          end

        slot.meta
        |> Map.get(:item_dep_paths, [])
        |> Enum.reduce(index, fn
          {^binding, [field | _rest]}, index when is_atom(field) ->
            Map.update(index, field, MapSet.new(addrs), fn set ->
              Enum.reduce(addrs, set, &MapSet.put(&2, &1))
            end)

          _other_binding, index ->
            index
        end)
      end)
      |> case do
        index when map_size(index) > 0 -> index
        _empty -> nil
      end
    else
      _no_index -> nil
    end
  end

  # The keyed-list slot at `addr`, searched through the compiled table's slot
  # map and recursively through a keyed slot's `item_slot_ids` (each inside
  # each). Arm-nested keyed slots are first-class table slots (registered
  # under their `addr/t|f` prefix), so the top-level scan finds them
  # directly. The address prefix relation (`addr` extends the container's
  # addr) prunes the descent.
  defp find_keyed_slot(%Table{} = table, addr),
    do: find_keyed_slot(table, Table.root_slots(table), addr)

  defp find_keyed_slot(table, slots, addr) do
    Enum.find_value(slots, fn {_id, slot} ->
      case slot do
        %{kind: :keyed_list, addr: slot_addr} = slot ->
          cond do
            slot_addr == addr ->
              slot

            String.starts_with?(addr, slot_addr <> "/") ->
              find_keyed_slot(table, Table.item_slots(table, slot), addr)

            true ->
              nil
          end

        _other_slot ->
          nil
      end
    end)
  end

  # The neutral diff kernel retains old/new keyed vars. When the keyed item is
  # passed straight into an embedded child, use that before-image to derive the
  # child's exact changed addresses instead of evaluating every row dynamic.
  # Native LiveView sends boolean changed markers and therefore keeps its own
  # existing path; transformed/multi-input children safely fall back to :all.
  defp precise_entry_child_changed(opts, child_table, %_{} = record) do
    case Map.get(opts, :entry_vars_changed) do
      %{item: {:changed, %resource{} = old, %resource{} = new}} = changed
      when map_size(changed) == 1 and new == record ->
        {:ok, Runtime.changed_addresses(child_table, old, new)}

      %{item: {:changed, old, new}} = changed
      when map_size(changed) == 1 and is_map(old) and is_map(new) ->
        fields = Map.keys(new)

        if Map.take(record, fields) == new and
             MapSet.new(Map.keys(old)) == MapSet.new(fields) do
          {:ok, Runtime.changed_addresses(child_table, struct(record, old), record)}
        else
          :error
        end

      _not_a_direct_item_change ->
        :error
    end
  end

  # `:all` means the surrounding dynamic is eligible; LiveView's own entry
  # vars still decide whether an existing keyed row changed. Only an explicit
  # child-write marker overrides that comparison.
  defp force_entry?(:all, _addr, _key), do: false

  defp force_entry?(%MapSet{} = changed, addr, key_component) do
    MapSet.member?(changed, {:entry, addr, key_component}) or
      MapSet.member?(changed, {:force_entries, addr})
  end

  defp force_entry?(_changed, _addr, _key), do: false

  # Item in item_bindings; ordinal in index_bindings — expression
  # evaluation reads declared indexes from index_bindings.
  defp item_scope_template(parent_scope, item) do
    item_paths = Map.get(parent_scope.context, :__bp_item_paths__, %{})

    source_path = expression_path(Map.get(item, :source), item_paths)

    scope = %{
      parent_scope
      | context: Map.put(parent_scope.context, :__bp_item_paths__, item_paths)
    }

    index_binding = if item.index in [nil, item.as], do: nil, else: item.index
    {scope, item_paths, source_path, item.as, index_binding}
  end

  defp item_scope({scope, item_paths, source_path, as, index_binding}, entry, index) do
    context =
      case source_path do
        path when is_list(path) ->
          Map.put(scope.context, :__bp_item_paths__, Map.put(item_paths, as, path ++ [index]))

        _unknown ->
          scope.context
      end

    scope = %{
      scope
      | item_bindings: Map.put(scope.item_bindings, as, entry),
        context: context
    }

    if is_nil(index_binding) do
      scope
    else
      %{scope | index_bindings: Map.put(scope.index_bindings, index_binding, index)}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp put_entry_children(opts, skeleton) do
    existing = Map.fetch!(opts, :entry_children)
    table = Map.fetch!(opts, :table)
    target = Map.fetch!(opts, :target)

    children =
      skeleton
      |> child_refs()
      |> Enum.reduce(existing, fn {addr, resource}, children ->
        Map.put_new_lazy(children, addr, fn ->
          child_info(table, target, addr, resource)
        end)
      end)

    if children == existing, do: opts, else: %{opts | entry_children: children}
  end

  defp child_refs(%Skeleton{dynamics: dynamics}), do: Enum.flat_map(dynamics, &child_refs/1)

  defp child_refs({:child, addr, resource, _input_eval, _embedded?}),
    do: [{addr, resource}]

  defp child_refs({:branch, _addr, _cond_eval, arms}) do
    child_refs(arms.true) ++ child_refs(arms.false)
  end

  defp child_refs({:keyed, _addr, _items_eval, item}), do: child_refs(item.skeleton)
  defp child_refs({:fragment_input, _addr, _parent_resource, skeleton}), do: child_refs(skeleton)
  defp child_refs(nil), do: []
  defp child_refs(_ref), do: []

  defp child_info(opts, addr, resource) do
    case Map.fetch(Map.fetch!(opts, :entry_children), addr) do
      {:ok, info} ->
        info

      :error ->
        child_info(
          Map.fetch!(opts, :table),
          Map.fetch!(opts, :target),
          addr,
          resource
        )
    end
  end

  defp child_info(table, target, addr, resource) do
    {error_record, direct_fragment_inputs} =
      case Compiler.child_slot(table, addr) do
        %{meta: meta} ->
          {Map.get(meta, :record), Map.get(meta, :direct_fragment_inputs, [])}

        _projection ->
          {nil, []}
      end

    child_table =
      Map.get(table.children, addr) || Compiler.table(resource, target: target)

    {child_table, error_record, Compiler.addr_component(addr), direct_fragment_inputs}
  end

  defp expression_path(%AshUi.Expr.Compiled{ir: ir}, item_paths),
    do: expression_path(ir, item_paths)

  defp expression_path({:_ref, path, field}, _item_paths)
       when is_list(path) and is_atom(field),
       do: path ++ [field]

  defp expression_path({:_item, binding, []}, item_paths) when is_atom(binding),
    do: Map.get(item_paths, binding)

  defp expression_path({:_item, binding, path}, item_paths)
       when is_atom(binding) and is_list(path) do
    case Map.get(item_paths, binding) do
      base when is_list(base) -> base ++ path
      _missing -> nil
    end
  end

  defp expression_path(_expression, _item_paths), do: nil

  defp scope(resource, record, opts) do
    errors = Map.get(opts, :errors, [])

    context =
      opts
      |> Map.get(:context, %{})
      |> Map.put(:__bp_all_errors__, errors)
      |> Map.put(:__bp_error_path__, [])

    Scope.new(record, Map.get(opts, :params, %{}),
      ash_resource_module: resource,
      actor: Map.get(opts, :actor),
      tenant: Map.get(opts, :tenant),
      context: context,
      errors: AshUi.errors_at_path(errors, []),
      __bp_all_errors__: errors
    )
  end

  defp truthy?(value), do: value not in [nil, false]
end
