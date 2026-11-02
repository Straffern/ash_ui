defmodule AshUi.Transformers.PersistStaticBlueprint do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias AshUi.Dsl.{RouteParam, RouteQuery}
  alias Spark.Dsl.Transformer

  @impl true
  def before?(transformer) do
    transformer
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Ash.Resource.Transformers.")
  end

  @impl true
  def transform(dsl_state) do
    reject_authored_session_provisioning!(dsl_state)
    explicit_mount_arguments = explicit_mount_arguments(dsl_state)

    dsl_state =
      dsl_state
      |> derive_declared_routes()
      |> maybe_ensure_route_state_attributes()
      |> maybe_allow_non_atomic_instance_mutations()
      |> maybe_ensure_context_multitenancy()
      |> maybe_ensure_mount_action()
      |> maybe_augment_mount_action()
      |> maybe_populate_declared_session_id()
      |> maybe_ensure_boundary_read_action()
      |> maybe_lower_render_tree_calculations()

    %{resource: resource, blueprint: persisted_blueprint} =
      AshUi.StaticCompile.snapshot!(dsl_state)

    view_exprs = AshUi.StaticCompile.view_exprs(resource)
    blueprint_hash = :crypto.hash(:sha256, :erlang.term_to_binary(persisted_blueprint))

    {compiled_eval_clauses, compiled_eval_hashes} = compiled_evals(view_exprs)

    register_strict_verifier_hook(dsl_state)

    effective_stylesheets = effective_stylesheets(dsl_state, resource)
    register_stylesheet_external_resources(dsl_state, effective_stylesheets)

    dsl_state =
      dsl_state
      |> Spark.Dsl.Transformer.persist(:ash_ui_compiled_resource, resource)
      |> Spark.Dsl.Transformer.persist(:ash_ui_view_exprs, view_exprs)
      |> Spark.Dsl.Transformer.persist(:ash_ui_compiled_blueprint, persisted_blueprint)
      |> Spark.Dsl.Transformer.persist(:ash_ui_compiled_blueprint_hash, blueprint_hash)
      |> Spark.Dsl.Transformer.persist(
        :ash_ui_strict_expressions?,
        resource.strict_expressions?
      )
      |> Spark.Dsl.Transformer.persist(:ash_ui_stylesheets, effective_stylesheets)
      |> Spark.Dsl.Transformer.persist(
        :ash_ui_explicit_mount_arguments,
        explicit_mount_arguments
      )
      |> Spark.Dsl.Transformer.persist(
        :ash_ui_deferred_checks,
        Map.get(resource, :deferred_checks, [])
      )
      |> Spark.Dsl.Transformer.eval(
        [blueprint_hash: blueprint_hash],
        quote do
          @doc false
          def __ash_ui_blueprint_hash__, do: unquote(Macro.escape(blueprint_hash))
        end
      )
      |> Spark.Dsl.Transformer.eval(
        [
          compiled_eval_clauses: compiled_eval_clauses,
          compiled_eval_hashes: compiled_eval_hashes
        ],
        quote do
          unquote_splicing(compiled_eval_clauses)

          @doc false
          def __bp_compiled_evals__, do: unquote(Macro.escape(compiled_eval_hashes))
        end
      )

    {:ok, dsl_state}
  end

  defp compiled_evals(view_exprs) do
    clauses_by_hash =
      view_exprs
      |> Map.values()
      |> Enum.flat_map(fn expr ->
        expr
        |> AshUi.ViewConstructor.lower()
        |> AshUi.Patch.Compiler.inline_pure_children()
        |> AshUi.Patch.Compiler.collect_exprs()
      end)
      |> Enum.reduce(%{}, fn %{ir: ir}, acc ->
        case AshUi.Patch.EvalCompiler.clause(ir) do
          {:ok, hash, clause} -> Map.put_new(acc, hash, clause)
          :error -> acc
        end
      end)

    {Map.values(clauses_by_hash), MapSet.new(Map.keys(clauses_by_hash))}
  end

  # Supplier seam (DESIGN.md §9): a substrate extension's transformer may SUPPLY
  # the effective stylesheets by persisting `{:ash_ui, :supplied_stylesheets}`
  # (a list). When supplied, it wins over locally declared `stylesheets`; the
  # resolution verifier turns "supplied AND declared" into a teaching compile
  # error. `nil` supplied means the resource supplies its own declared set.
  defp effective_stylesheets(dsl_state, resource) do
    case Spark.Dsl.Transformer.get_persisted(
           dsl_state,
           {:ash_ui, :supplied_stylesheets},
           nil
         ) do
      supplied when is_list(supplied) -> supplied
      _none -> Map.get(resource, :stylesheets, []) || []
    end
  end

  # Register each declared/supplied sheet that exists as an `@external_resource`
  # so editing the CSS recompiles the declaring resource and coverage cannot go
  # stale (DESIGN.md §9). Missing/unreadable files are left to the coverage
  # verifier to report as teaching errors.
  defp register_stylesheet_external_resources(dsl_state, stylesheets) do
    case Spark.Dsl.Transformer.get_persisted(dsl_state, :module) do
      module when is_atom(module) ->
        Enum.each(stylesheets, fn path ->
          abs = Path.expand(path, File.cwd!())

          if File.regular?(abs) do
            Module.put_attribute(module, :external_resource, abs)
          end
        end)

      _other ->
        :ok
    end
  end

  defp register_strict_verifier_hook(dsl_state) do
    case Spark.Dsl.Transformer.get_persisted(dsl_state, :module) do
      module when is_atom(module) ->
        Module.put_attribute(
          module,
          :after_compile,
          {AshUi.Verifiers.StrictAfterVerify, :__after_compile__}
        )

      _other ->
        :ok
    end
  end

  defp maybe_ensure_boundary_read_action(dsl_state) do
    if primary_read_action?(dsl_state) do
      dsl_state
    else
      {:ok, dsl_state} =
        Ash.Resource.Builder.add_action(
          dsl_state,
          :read,
          :__ash_ui_boundary_read__,
          primary?: true,
          skip_unknown_inputs: [:*]
        )

      dsl_state
    end
  end

  defp primary_read_action?(dsl_state) do
    dsl_state
    |> Spark.Dsl.Transformer.get_entities([:actions])
    |> Enum.any?(&match?(%{type: :read, primary?: true}, &1))
  end

  defp maybe_lower_render_tree_calculations(dsl_state) do
    dsl_state
    |> Spark.Dsl.Transformer.get_entities([:calculations])
    |> Enum.reduce(dsl_state, fn calculation, acc ->
      if render_tree_expression_calculation?(calculation) do
        {Ash.Resource.Calculation.Expression, expression_opts} = calculation.calculation

        updated =
          Map.put(
            calculation,
            :calculation,
            {AshUi.ViewCalculation,
             [
               view: calculation.name,
               resource: Spark.Dsl.Transformer.get_persisted(dsl_state, :module),
               expr: Keyword.fetch!(expression_opts, :expr)
             ]}
          )

        Spark.Dsl.Transformer.replace_entity(
          acc,
          [:calculations],
          updated,
          &(&1.name == calculation.name)
        )
      else
        acc
      end
    end)
  end

  defp render_tree_expression_calculation?(%{
         type: AshUi.Type.RenderTree,
         calculation: {Ash.Resource.Calculation.Expression, opts}
       })
       when is_list(opts),
       do: Keyword.has_key?(opts, :expr)

  defp render_tree_expression_calculation?(_calculation), do: false

  defp maybe_ensure_route_state_attributes(dsl_state) do
    dsl_state
    |> route_state_mount_attributes()
    |> Enum.reduce(dsl_state, fn %{name: name, type: type, default: default}, acc ->
      maybe_ensure_public_attribute(acc, name, type || :string, default: default)
    end)
  end

  defp maybe_ensure_public_attribute(dsl_state, name, type, opts)
       when is_atom(name) and not is_nil(type) do
    if Enum.any?(
         Transformer.get_entities(dsl_state, [:attributes]),
         &(&1.name == name)
       ) do
      dsl_state
    else
      {:ok, dsl_state} =
        Ash.Resource.Builder.add_new_attribute(
          dsl_state,
          name,
          type,
          allow_nil?: true,
          default: Keyword.get(opts, :default),
          public?: true
        )

      dsl_state
    end
  end

  defp maybe_ensure_public_attribute(dsl_state, _name, _type, _opts), do: dsl_state

  defp maybe_ensure_mount_action(dsl_state) do
    if mount_action(dsl_state) do
      dsl_state
    else
      {:ok, dsl_state} =
        Ash.Resource.Builder.add_action(
          dsl_state,
          :create,
          :mount,
          skip_unknown_inputs: [:*],
          transaction?: false
        )

      dsl_state
    end
  end

  defp maybe_augment_mount_action(dsl_state) do
    case mount_action(dsl_state) do
      nil ->
        dsl_state

      action ->
        arguments = mount_action_arguments(dsl_state, action)
        changes = mount_action_changes(dsl_state, action)

        updated_action = %{
          action
          | arguments: action.arguments ++ arguments,
            changes: action.changes ++ changes,
            skip_unknown_inputs: Enum.uniq(List.wrap(action.skip_unknown_inputs) ++ [:*])
        }

        Transformer.replace_entity(
          dsl_state,
          [:actions],
          updated_action,
          &(&1.name == :mount and &1.type == :create)
        )
    end
  end

  defp mount_action(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.find(&(&1.name == :mount and &1.type == :create))
  end

  # Capture authored arguments before the transformer synthesizes mount
  # arguments for resource attributes. A host bridge uses this small
  # persisted set as the only non-route exception to closed URL input.
  defp explicit_mount_arguments(dsl_state) do
    case mount_action(dsl_state) do
      nil -> []
      action -> Enum.map(action.arguments, & &1.name)
    end
  end

  defp mount_action_arguments(dsl_state, action) do
    existing = MapSet.new(action.arguments, & &1.name)

    dsl_state
    |> mount_argument_specs()
    |> Enum.reject(&MapSet.member?(existing, &1.name))
    |> Enum.map(fn spec ->
      {:ok, argument} =
        Ash.Resource.Builder.build_action_argument(
          spec.name,
          spec.type || :term,
          allow_nil?: true,
          default: Map.get(spec, :default),
          constraints: Map.get(spec, :constraints, [])
        )

      argument
    end)
  end

  defp mount_action_changes(dsl_state, action) do
    changed_fields = action_change_fields(action)

    argument_changes =
      dsl_state
      |> mount_argument_specs()
      |> Enum.reject(&MapSet.member?(changed_fields, &1.name))
      |> Enum.map(fn spec ->
        mount_set_attribute_change(spec.name, Ash.Expr.arg(spec.name),
          set_when_nil?: false,
          new?: false
        )
      end)

    argument_changes
  end

  defp maybe_populate_declared_session_id(dsl_state) do
    if attribute_declared?(dsl_state, :session_id) do
      dsl_state
      |> Transformer.get_entities([:actions])
      |> Enum.reduce(dsl_state, fn
        %{type: :create} = action, acc ->
          updated_action = %{
            action
            | changes: action.changes ++ [session_id_change()],
              skip_unknown_inputs: Enum.uniq(List.wrap(action.skip_unknown_inputs) ++ [:*])
          }

          Transformer.replace_entity(
            acc,
            [:actions],
            updated_action,
            &(&1.name == action.name and &1.type == :create)
          )

        _action, acc ->
          acc
      end)
    else
      dsl_state
    end
  end

  defp session_id_change do
    {:ok, change} = Ash.Resource.Builder.build_change(AshUi.Changes.SetSessionId)
    change
  end

  defp reject_authored_session_provisioning!(dsl_state) do
    case dsl_state
         |> Transformer.get_entities([:actions])
         |> Enum.find(fn action ->
           Enum.any?(Map.get(action, :changes, []), fn
             %Ash.Resource.Change{change: {AshUi.Changes.SetSessionId, _opts}} -> true
             _other -> false
           end)
         end) do
      nil ->
        :ok

      action ->
        raise Spark.Error.DslError,
          module: Transformer.get_persisted(dsl_state, :module),
          path: [:actions, action.type, action.name],
          message: """
          #{inspect(AshUi.Changes.SetSessionId)} is supplied by AshUi.

          Every create action on an AshUi resource that declares :session_id
          receives session provisioning from the resource transformer. A local
          change would run the same provisioning twice and create a second
          lifecycle channel. Remove:

              change AshUi.Changes.SetSessionId

          Session identity continues to arrive from the changeset context.
          See the ash_ui DESIGN.md §2.
          """
    end
  end

  # Routing is 100% DSL derived: every `routes do route ... end` entity
  # declares its address template plus TYPED param/query bindings; the
  # template and the declared params must match exactly (no magic
  # segments). Declarations aggregate into the internal [:route] section
  # (mount-arg and route-state generation read it), the ordered route
  # list, and the introspection functions the router/bridge consume. The
  # first declared route is the canonical projection template.
  defp derive_declared_routes(dsl_state) do
    case Transformer.get_entities(dsl_state, [:routes]) do
      [] ->
        dsl_state

      routes ->
        Enum.each(routes, &verify_route_params!(dsl_state, &1))

        existing_names =
          dsl_state
          |> Transformer.get_entities([:route])
          |> Enum.map(& &1.name)
          |> MapSet.new()

        {dsl_state, _seen} =
          routes
          |> Enum.flat_map(&(&1.params ++ &1.queries))
          |> Enum.reduce({dsl_state, existing_names}, fn entity, {dsl_state, seen} ->
            if MapSet.member?(seen, entity.name) do
              {dsl_state, seen}
            else
              {Transformer.add_entity(dsl_state, [:route], entity), MapSet.put(seen, entity.name)}
            end
          end)

        route_list =
          Enum.map(routes, fn route -> {route.path, Enum.map(route.queries, & &1.name)} end)

        location =
          Enum.find_value(routes, fn route ->
            case route.location do
              nil -> nil
              expression -> AshUi.ExprCompiler.compile!(expression)
            end
          end)

        dsl_state
        |> Spark.Dsl.Transformer.persist(:ash_ui_declared_routes, route_list)
        |> Spark.Dsl.Transformer.eval(
          [route_list: route_list, location: location],
          quote do
            def __ash_ui_routes__, do: unquote(Macro.escape(route_list))
            def __ash_ui_route__, do: hd(__ash_ui_routes__())

            def __ash_ui_route_location__,
              do: unquote(Macro.escape(location))
          end
        )
    end
  end

  defp verify_route_params!(dsl_state, route) do
    template = route.path |> route_path_param_names() |> Enum.sort()
    declared = route.params |> Enum.map(& &1.name) |> Enum.sort()

    if template != declared do
      raise Spark.Error.DslError,
        module: Transformer.get_persisted(dsl_state, :module),
        path: [:routes, :route, route.path],
        message:
          "route params must declare the template's :segments exactly — " <>
            "template binds #{inspect(template)}, declared #{inspect(declared)}"
    end
  end

  defp route_path_param_names(path) do
    ~r/(^|\/)[:*]([A-Za-z_][A-Za-z0-9_]*)(?=\/|$)/
    |> Regex.scan(path, capture: :all_but_first)
    |> Enum.map(fn [_slash, name] -> String.to_atom(name) end)
  end

  defp mount_argument_specs(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:attributes])
    |> Enum.map(fn attribute ->
      %{
        name: attribute.name,
        type: Map.get(attribute, :type) || :term,
        default: nil,
        constraints: Map.get(attribute, :constraints, [])
      }
    end)
  end

  defp action_change_fields(action) do
    action.changes
    |> Enum.flat_map(fn
      %Ash.Resource.Change{change: {Ash.Resource.Change.SetAttribute, opts}} ->
        [Keyword.get(opts, :attribute)]

      _other ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp mount_set_attribute_change(field, expr, opts) do
    change_spec =
      if Keyword.get(opts, :new?, false) do
        {Ash.Resource.Change.AtomicSet, attribute: field, expr: expr, cast_atomic?: true}
      else
        {Ash.Resource.Change.SetAttribute,
         attribute: field,
         value: expr,
         set_when_nil?: Keyword.get(opts, :set_when_nil?, true),
         new?: false}
      end

    {:ok, change} = Ash.Resource.Builder.build_change(change_spec)

    change
  end

  defp attribute_declared?(dsl_state, name) do
    dsl_state
    |> Transformer.get_entities([:attributes])
    |> Enum.any?(&(&1.name == name))
  end

  defp route_state_mount_attributes(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:route])
    |> Enum.flat_map(&route_option_state_attribute/1)
    |> Enum.uniq_by(& &1.name)
  end

  defp route_option_state_attribute(%RouteQuery{state: state} = query)
       when is_atom(state) and not is_nil(state) do
    [%{name: state, type: query.type || :string, default: query.default}]
  end

  defp route_option_state_attribute(%RouteParam{state: state} = param)
       when is_atom(state) and not is_nil(state) do
    [%{name: state, type: param.type || :string, default: param.default}]
  end

  defp route_option_state_attribute(_other), do: []

  defp maybe_allow_non_atomic_instance_mutations(dsl_state) do
    if ets_backed?(dsl_state) do
      dsl_state
      |> Spark.Dsl.Transformer.get_entities([:actions])
      |> Enum.reduce(dsl_state, fn
        %{type: type, require_atomic?: true} = action, acc when type in [:update, :destroy] ->
          Spark.Dsl.Transformer.replace_entity(
            acc,
            [:actions],
            %{action | require_atomic?: false},
            &(&1.name == action.name and &1.type == action.type)
          )

        _action, acc ->
          acc
      end)
    else
      dsl_state
    end
  end

  defp ets_backed?(dsl_state) do
    actual =
      Spark.Dsl.Transformer.get_persisted(dsl_state, :data_layer) ||
        Spark.Dsl.Transformer.get_option(dsl_state, [:resource], :data_layer)

    AshUi.BenchDataLayer.entity_data_layer?(actual)
  end

  defp maybe_ensure_context_multitenancy(dsl_state) do
    case Spark.Dsl.Transformer.get_option(dsl_state, [:multitenancy], :strategy) do
      nil ->
        dsl_state
        |> Spark.Dsl.Transformer.set_option([:multitenancy], :strategy, :context)
        |> Spark.Dsl.Transformer.set_option([:multitenancy], :global?, true)

      _strategy ->
        dsl_state
    end
  end
end
