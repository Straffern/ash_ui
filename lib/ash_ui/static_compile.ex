defmodule AshUi.StaticCompile do
  @moduledoc false

  alias Ash.Resource.Attribute, as: AshAttribute
  alias Ash.Resource.Actions, as: AshActions
  alias Ash.Resource.Actions.Argument, as: AshArgument
  alias Ash.Resource.Calculation, as: AshCalculation
  alias Ash.Resource.Relationships.{BelongsTo, HasMany, HasOne}

  alias AshUi.Dsl.{
    RouteParam,
    RouteQuery
  }

  alias AshUi.Expr.Compiled
  alias AshUi.ExprCompiler
  alias AshUi.ResourceBlueprint
  alias Spark.Dsl.{Extension, Transformer}
  alias Spark.Error.DslError

  @spec snapshot!(module() | map()) :: %{resource: ResourceBlueprint.t(), blueprint: map()}
  def snapshot!(source) when is_atom(source) or is_map(source) do
    resource = compile!(source)

    %{
      resource: resource,
      blueprint: AshUi.Compiled.blueprint!(resource)
    }
  rescue
    error in DslError ->
      raise located_dsl_error(source, [:ash_ui], error)

    error in ArgumentError ->
      raise located_argument_error(source, [:ash_ui], error)
  end

  @spec view_exprs(ResourceBlueprint.t()) :: map()
  def view_exprs(%ResourceBlueprint{} = resource) do
    resource.calculations
    |> Enum.filter(&render_tree_calculation?/1)
    |> Map.new(&{&1.name, &1.expr})
  end

  @spec resource_definition!(module() | map()) :: map()
  def resource_definition!(module) when is_atom(module) do
    ensure_blueprint_module!(module)
    load_static_resource(module, module)
  end

  def resource_definition!(dsl_state) when is_map(dsl_state) do
    module =
      case Transformer.fetch_persisted(dsl_state, :module) do
        {:ok, module} ->
          module

        :error ->
          raise ArgumentError, "expected AshUi DSL state with persisted :module metadata"
      end

    ensure_blueprint_dsl_state!(dsl_state, module)
    load_static_resource(dsl_state, module)
  end

  @spec compile!(module() | map()) :: ResourceBlueprint.t()
  def compile!(source) when is_atom(source) or is_map(source) do
    source
    |> resource_definition!()
    |> normalize_resource!()
  rescue
    error in DslError ->
      raise located_dsl_error(source, [:ash_ui], error)

    error in ArgumentError ->
      raise located_argument_error(source, [:ash_ui], error)
  end

  defp normalize_resource!(%{} = resource) do
    metadata =
      resource_metadata(resource.source)
      |> Map.update(:data_layer, Map.get(resource, :data_layer), fn data_layer ->
        data_layer || Map.get(resource, :data_layer)
      end)

    relationships = Enum.map(resource.relationships, &normalize_relationship/1)

    attributes =
      resource.attributes
      |> Enum.map(&normalize_attribute/1)
      |> ensure_primary_key()
      |> ensure_relationship_attributes(relationships)

    route =
      resource
      |> Map.get(:route, %{queries: []})
      |> append_attribute_route_states(attributes)
      |> normalize_route()

    config = normalize_config(Map.get(resource, :config, %{}), metadata.data_layer)

    actions = Enum.map(resource.actions, &normalize_action/1)

    calculations =
      resource.calculations
      |> Enum.map(&normalize_calculation/1)

    raw_view = Map.get(resource, :view) || view_from_calculations(calculations, :view)

    view = normalize_optional_view(raw_view)

    struct(
      ResourceBlueprint,
      id: resource.name,
      name: resource.name,
      module: metadata.module,
      domain: metadata.domain,
      extensions: metadata.extensions,
      data_layer: metadata.data_layer,
      attributes: attributes,
      relationships: relationships,
      actions: actions,
      calculations: calculations,
      aggregates: Map.get(resource, :aggregates, []),
      route: route,
      deferred_checks: deferred_checks(resource, metadata),
      dynamic_map_props: [],
      client_drivers: collect_client_drivers(view),
      stylesheets: Map.get(resource, :stylesheets, []),
      view: view,
      strict_expressions?: config.strict_expressions?,
      source: resource.source
    )
    |> finalize_expression_calls!(metadata.module)
  end

  defp load_static_resource(source, module) do
    attributes =
      source
      |> load_ash_attributes(module)
      |> append_route_state_attributes(source)
      |> ensure_primary_key_attribute()

    config = load_config(source, module)

    view = load_view(source)

    %{
      name: resource_name(source, module),
      attributes: attributes,
      relationships: load_relationships(source, module),
      actions: load_actions(source, module, attributes),
      calculations: load_calculations(source, module),
      aggregates: load_aggregates(source, module),
      route: %{
        params: source |> dsl_entities([:route]) |> Enum.flat_map(&load_route_param/1),
        queries: source |> dsl_entities([:route]) |> Enum.flat_map(&load_route_query(module, &1)),
        states: load_route_states(source, attributes, source |> dsl_entities([:route]))
      },
      stylesheets: Map.get(config, :stylesheets, []),
      view: view,
      config: config,
      data_layer: source_data_layer(source, module),
      source: {:static, module}
    }
  end

  defp load_view(_source), do: nil

  defp located_argument_error(source, path, %ArgumentError{} = error) do
    case source_module(source) do
      module when is_atom(module) and not is_nil(module) ->
        DslError.exception(
          module: module,
          path: List.wrap(path),
          message: sanitize_argument_message(Exception.message(error))
        )

      _other ->
        error
    end
  end

  defp located_dsl_error(_source, _path, %DslError{module: module} = error)
       when not is_nil(module),
       do: error

  defp located_dsl_error(source, path, %DslError{} = error) do
    case source_module(source) do
      module when is_atom(module) and not is_nil(module) ->
        DslError.exception(
          module: module,
          path: List.wrap(path),
          message: Exception.message(error)
        )

      _other ->
        error
    end
  end

  defp source_module(%{source: {:static, module}}) when is_atom(module), do: module
  defp source_module({:static, module}) when is_atom(module), do: module
  defp source_module(module) when is_atom(module), do: module

  defp source_module(source) when is_map(source) do
    case Transformer.fetch_persisted(source, :module) do
      {:ok, module} when is_atom(module) -> module
      _other -> nil
    end
  rescue
    error in [ArgumentError, FunctionClauseError] ->
      _ = error
      nil
  end

  defp source_module(_source), do: nil

  defp sanitize_argument_message(message) when is_binary(message) do
    message
    |> String.replace(~r/got: %\{.*\}\z/s, "got an unsupported map value")
    |> String.replace(~r/: %\{.*\}\z/s, ": unsupported map value")
  end

  defp deferred_checks(%{relationships: relationships}, metadata) do
    Enum.flat_map(relationships || [], fn
      %{name: name, destination: module} when is_atom(module) ->
        if Code.ensure_loaded?(module) do
          []
        else
          [
            %{
              kind: :relationship_destination,
              reason: :module_not_loaded,
              module: metadata.module,
              path: [:relationships, name],
              relationship: name,
              destination: module,
              message: "deferred module #{inspect(module)} is not loaded"
            }
          ]
        end

      _relationship ->
        []
    end)
  end

  defp dsl_entities(source, path) when is_atom(source), do: Extension.get_entities(source, path)

  defp dsl_entities(source, [section] = path) when is_map(source) do
    case Transformer.get_entities(source, path) do
      [] -> Transformer.get_entities(source, section)
      entities -> entities
    end
  end

  defp dsl_option(source, path, option) when is_atom(source),
    do: Extension.get_opt(source, path, option)

  defp dsl_option(source, [section] = path, option) when is_map(source) do
    case Transformer.fetch_option(source, path, option) do
      {:ok, value} -> value
      :error -> Transformer.get_option(source, section, option)
    end
  end

  defp source_data_layer(source, module) when is_map(source) do
    Transformer.get_persisted(source, :data_layer) ||
      dsl_option(source, [:resource], :data_layer) ||
      resource_data_layer(module)
  end

  defp source_data_layer(_source, module), do: resource_data_layer(module)

  defp load_ash_attributes(source, module) do
    generated_belongs_to_attributes =
      ash_relationships(source, module)
      |> Enum.flat_map(fn
        %BelongsTo{define_attribute?: true, source_attribute: source_attribute} ->
          [source_attribute]

        _other ->
          []
      end)
      |> MapSet.new()

    ash_attributes(source, module)
    |> Enum.reject(fn attribute ->
      MapSet.member?(generated_belongs_to_attributes, attribute.name)
    end)
    |> Enum.map(&load_ash_attribute/1)
  end

  defp load_ash_attribute(%AshAttribute{} = attribute) do
    default =
      if attribute.primary_key? and integer_type?(attribute.type) and
           is_function(attribute.default, 0) do
        nil
      else
        attribute.default
      end

    %{
      name: attribute.name,
      type: attribute.type,
      required?: if(attribute.primary_key?, do: false, else: not attribute.allow_nil?),
      default: default,
      route: nil,
      primary_key?: attribute.primary_key?,
      public?: Map.get(attribute, :public?, false)
    }
  end

  defp ensure_primary_key_attribute(attributes) do
    attributes =
      if Enum.any?(attributes, & &1[:primary_key?]) do
        attributes
      else
        [
          %{
            name: :id,
            type: Ash.Type.Integer,
            default: nil,
            primary_key?: true,
            required?: false,
            public?: true
          }
          | attributes
        ]
      end

    primary_keys = Enum.filter(attributes, & &1[:primary_key?])
    non_primary_keys = Enum.reject(attributes, & &1[:primary_key?])
    primary_keys ++ non_primary_keys
  end

  defp integer_type?(type) when type in [:integer, Ash.Type.Integer], do: true
  defp integer_type?(_type), do: false

  defp load_relationships(source, module) do
    ash_relationships(source, module)
    |> Enum.map(&load_relationship/1)
    |> Enum.reject(&is_nil/1)
  end

  defp load_actions(source, module, attributes) do
    ash_actions(source, module)
    |> Enum.flat_map(&load_ash_actions(source, module, attributes, &1))
  end

  defp load_calculations(source, module) do
    ash_calculations(source, module)
    |> Enum.map(&load_ash_calculation/1)
  end

  defp load_aggregates(source, module) do
    source
    |> ash_aggregates(module)
    |> Enum.map(&%{name: &1.name, kind: &1.kind, relationship_path: &1.relationship_path})
  end

  defp ash_aggregates(source, module) when is_atom(source),
    do: Ash.Resource.Info.aggregates(module)

  defp ash_aggregates(source, _module) when is_map(source),
    do: Transformer.get_entities(source, [:aggregates])

  defp ash_attributes(source, module) when is_atom(source),
    do: Ash.Resource.Info.attributes(module)

  defp ash_attributes(source, _module) when is_map(source),
    do: Transformer.get_entities(source, [:attributes])

  defp ash_relationships(source, module) when is_atom(source),
    do: Ash.Resource.Info.relationships(module)

  defp ash_relationships(source, _module) when is_map(source),
    do: Transformer.get_entities(source, [:relationships])

  defp ash_actions(source, module) when is_atom(source), do: Ash.Resource.Info.actions(module)

  defp ash_actions(source, module) when is_map(source) do
    module_actions =
      try do
        Ash.Resource.Info.actions(module)
      rescue
        error in [ArgumentError, UndefinedFunctionError] ->
          _ = error
          []
      end

    seen_names = MapSet.new(module_actions, & &1.name)

    module_actions ++
      Enum.reject(
        Transformer.get_entities(source, [:actions]),
        &MapSet.member?(seen_names, &1.name)
      )
  end

  defp ash_calculations(source, module) when is_atom(source),
    do: Ash.Resource.Info.calculations(module)

  defp ash_calculations(source, _module) when is_map(source),
    do: Transformer.get_entities(source, [:calculations])

  defp load_ash_actions(source, module, _attributes, %struct{} = action)
       when struct in [
              AshActions.Create,
              AshActions.Update,
              AshActions.Destroy,
              AshActions.Action
            ] do
    reject_unsupported_ash_action_metadata!(action)

    if dsl_action?(action) do
      accepted_arguments = List.wrap(Map.get(action, :accept, []))

      [
        %{
          name: action.name,
          type: action.type,
          arguments: load_action_arguments(source, module, action, accepted_arguments),
          changes: [],
          client_actions: []
        }
      ]
    else
      []
    end
  end

  defp load_ash_actions(_source, _module, _attributes, _action), do: []

  defp load_ash_calculation(%AshCalculation{} = calculation) do
    %{
      name: calculation.name,
      type: calculation.type,
      constraints: calculation.constraints || [],
      calculation: calculation.calculation,
      expr: unwrap_ash_calculation(calculation.calculation),
      allow_nil?: calculation.allow_nil?
    }
  end

  defp load_relationship(%BelongsTo{} = relationship) do
    %{
      name: relationship.name,
      type: :belongs_to,
      destination: relationship.destination,
      source_attribute: relationship.source_attribute,
      destination_attribute: relationship.destination_attribute,
      define_attribute?: relationship.define_attribute?,
      attribute_type: relationship.attribute_type,
      allow_nil?: relationship.allow_nil?,
      read_action: relationship.read_action,
      filter: relationship.filter,
      sort: relationship.sort,
      no_attributes?: false,
      required_parent_attrs: parent_attrs_from_filter(relationship.filter)
    }
  end

  defp load_relationship(%HasMany{} = relationship) do
    %{
      name: relationship.name,
      type: :has_many,
      destination: relationship.destination,
      source_attribute: relationship.source_attribute,
      destination_attribute: relationship.destination_attribute,
      read_action: relationship.read_action,
      filter: relationship.filter,
      sort: relationship.sort,
      limit: relationship.limit,
      offset: nil,
      no_attributes?: relationship.no_attributes?,
      required_parent_attrs: parent_attrs_from_filter(relationship.filter)
    }
  end

  defp load_relationship(%HasOne{} = relationship) do
    %{
      name: relationship.name,
      type: :has_one,
      destination: relationship.destination,
      source_attribute: relationship.source_attribute,
      destination_attribute: relationship.destination_attribute,
      read_action: relationship.read_action,
      filter: relationship.filter,
      sort: relationship.sort,
      offset: nil,
      no_attributes?: relationship.no_attributes?,
      allow_nil?: relationship.allow_nil?,
      required_parent_attrs: parent_attrs_from_filter(relationship.filter)
    }
  end

  defp load_relationship(_relationship), do: nil

  defp load_config(source, _module) do
    %{
      strict_expressions?:
        dsl_option(source, [:ash_ui], :strict_expressions?) ||
          :strict,
      stylesheets: dsl_option(source, [:ash_ui], :stylesheets) || []
    }
  end

  defp load_route_states(_source, attributes, route_entities) do
    option_states =
      route_entities
      |> Enum.flat_map(&load_route_option_state/1)

    attribute_states =
      attributes
      |> Enum.flat_map(fn
        %{route: nil} ->
          []

        %{name: name, type: type, route: route, default: default} ->
          [normalize_attribute_route(route, name, type, default)]

        _other ->
          []
      end)

    (option_states ++ attribute_states)
    |> Enum.uniq_by(& &1.name)
  end

  defp load_route_query(_module, %RouteQuery{} = query) do
    [%{name: query.name, type: query.type, default: query.default}]
  end

  defp load_route_query(_module, _other), do: []

  defp load_route_param(%RouteParam{} = param),
    do: [
      %{
        name: param.name,
        type: param.type,
        default: param.default,
        constraints: []
      }
    ]

  defp load_route_param(_other), do: []

  defp load_route_option_state(%RouteQuery{state: state} = query) when is_atom(state) do
    [
      %{
        name: state,
        type: query.type,
        query: query.name,
        param: query.name,
        constraints: [],
        default: query.default
      }
    ]
  end

  defp load_route_option_state(%RouteParam{state: state} = param) when is_atom(state) do
    [
      %{
        name: state,
        type: param.type,
        query: nil,
        param: param.name,
        constraints: [],
        default: param.default
      }
    ]
  end

  defp load_route_option_state(_other), do: []

  defp normalize_attribute_route(route, name, type, default)
       when is_list(route) or is_map(route) do
    route = normalize_optional_map(route)
    query = Map.get(route, :query)
    param = Map.get(route, :param)

    inferred_param =
      cond do
        not is_nil(param) -> param
        not is_nil(query) -> query
        true -> name
      end

    %{
      name: name,
      type: type,
      query: query,
      param: inferred_param,
      constraints: Map.get(route, :constraints, []),
      default: Map.get(route, :default, default)
    }
  end

  defp append_route_state_attributes(attributes, source) do
    existing_names = MapSet.new(attributes, & &1.name)

    route_states =
      source
      |> dsl_entities([:route])
      |> Enum.flat_map(&load_route_option_state/1)

    route_state_attrs =
      route_states
      |> Enum.reject(&MapSet.member?(existing_names, &1.name))
      |> Enum.map(fn route ->
        %{
          name: route.name,
          type: route.type,
          constraints: route.constraints || [],
          default: route.default,
          route: route,
          primary_key?: false,
          required?: false,
          public?: true
        }
      end)

    attributes ++ route_state_attrs
  end

  defp collect_client_drivers(view) do
    [view]
    |> Enum.flat_map(&collect_client_drivers_from_node/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp collect_client_drivers_from_node(nil), do: []

  defp collect_client_drivers_from_node(%{kind: :fragment, children: children}) do
    Enum.flat_map(children, &collect_client_drivers_from_node/1)
  end

  defp collect_client_drivers_from_node(%{kind: kind, children: children} = node)
       when kind in [:stack, :row, :element] do
    node
    |> Map.get(:meta, %{})
    |> Map.get(:client_drivers, [])
    |> List.wrap()
    |> Kernel.++(Enum.flat_map(children || [], &collect_client_drivers_from_node/1))
  end

  defp collect_client_drivers_from_node(%{kind: :when, child: child}) do
    collect_client_drivers_from_node(child)
  end

  defp collect_client_drivers_from_node(%{kind: :if, then: then_child} = node) do
    collect_client_drivers_from_node(then_child) ++
      collect_client_drivers_from_node(Map.get(node, :else))
  end

  defp collect_client_drivers_from_node(%{kind: :each, child: child}) do
    collect_client_drivers_from_node(child)
  end

  defp collect_client_drivers_from_node(%{kind: :attached_view, child: child}) do
    collect_client_drivers_from_node(child)
  end

  defp collect_client_drivers_from_node(%{kind: :resource_component, fills: fills}) do
    fills
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(&collect_client_drivers_from_node/1)
  end

  defp collect_client_drivers_from_node(_node), do: []

  defp resource_name(source, module) do
    short_name =
      case dsl_option(source, [:resource], :short_name) do
        nil when is_map(source) -> infer_name(module)
        nil -> Ash.Resource.Info.short_name(module)
        value -> value
      end

    case short_name do
      ^module -> infer_name(module)
      nil -> infer_name(module)
      value -> value
    end
  end

  defp infer_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp dsl_action?(action) do
    action.name != action.type or Map.get(action, :arguments, []) != [] or
      Map.get(action, :changes, []) != [] or Map.get(action, :metadata, []) != [] or
      List.wrap(Map.get(action, :accept, [])) != []
  end

  defp reject_unsupported_ash_action_metadata!(action) do
    unsupported =
      [
        :validations,
        :condition,
        :on_success,
        :on_error,
        :skip_global_validations?,
        :delay_global_validations?
      ]
      |> Enum.filter(fn key -> action_metadata_present?(Map.get(action, key)) end)

    if unsupported != [] do
      raise ArgumentError,
            "unsupported action metadata: #{inspect(Enum.sort(unsupported))} in #{inspect(action.name)}"
    end
  end

  defp action_metadata_present?(nil), do: false
  defp action_metadata_present?(false), do: false
  defp action_metadata_present?(value) when value in [%{}, []], do: false
  defp action_metadata_present?(_value), do: true

  defp load_action_arguments(source, module, action, accepted_arguments) do
    declared_arguments =
      Enum.map(Map.get(action, :arguments, []), fn %AshArgument{
                                                     name: name,
                                                     type: type,
                                                     allow_nil?: allow_nil?,
                                                     constraints: constraints
                                                   } ->
        %{name: name, type: type, allow_nil?: allow_nil?, constraints: constraints || []}
      end)

    inferred_arguments =
      accepted_arguments
      |> Enum.reject(fn accepted ->
        Enum.any?(declared_arguments, &(&1.name == accepted))
      end)
      |> Enum.map(fn accepted ->
        attribute =
          Ash.Resource.Info.attribute(module, accepted) ||
            Enum.find(ash_attributes(source, module), &(&1.name == accepted))

        %{
          name: accepted,
          type: attribute.type,
          allow_nil?: accepted not in List.wrap(Map.get(action, :require_attributes, [])),
          constraints: Map.get(attribute, :constraints, [])
        }
      end)

    declared_arguments ++ inferred_arguments
  end

  defp normalize_optional_map(value) when is_map(value), do: value
  defp normalize_optional_map(value) when is_list(value), do: Enum.into(value, %{})
  defp normalize_optional_map(value), do: value

  defp normalize_attribute(attribute) do
    %{
      name: Map.fetch!(attribute, :name),
      type: normalize_blueprint_type(Map.fetch!(attribute, :type)),
      default: Map.get(attribute, :default),
      route:
        case Map.get(attribute, :route) do
          nil -> nil
          route -> normalize_optional_map(route)
        end,
      primary_key?: Map.get(attribute, :primary_key?, false),
      required?: Map.get(attribute, :required?, false),
      public?: Map.get(attribute, :public?, false)
    }
  end

  defp ensure_primary_key(attributes) do
    if Enum.any?(attributes, & &1.primary_key?) do
      attributes
    else
      [
        %{
          name: :id,
          type: :integer,
          default: nil,
          primary_key?: true,
          required?: false,
          public?: true
        }
        | attributes
      ]
    end
  end

  defp ensure_relationship_attributes(attributes, relationships) do
    Enum.reduce(relationships, attributes, fn
      %{type: :belongs_to, define_attribute?: true} = relationship, acc ->
        if Enum.any?(acc, &(&1.name == relationship.source_attribute)) do
          acc
        else
          acc ++
            [
              %{
                name: relationship.source_attribute,
                type: normalize_blueprint_type(relationship.attribute_type || :uuid),
                default: nil,
                primary_key?: false,
                required?: not Map.get(relationship, :allow_nil?, true),
                public?: false
              }
            ]
        end

      _relationship, acc ->
        acc
    end)
  end

  defp normalize_action(action) do
    %{
      name: Map.fetch!(action, :name),
      type: normalize_action_type(action),
      when_variant: Map.get(action, :when_variant),
      arguments:
        Enum.map(Map.get(action, :arguments, []), fn argument ->
          %{
            name: Map.fetch!(argument, :name),
            type: normalize_blueprint_type(Map.fetch!(argument, :type)),
            allow_nil?: Map.get(argument, :allow_nil?, true),
            constraints: Map.get(argument, :constraints, [])
          }
        end),
      client_actions:
        action
        |> Map.get(:client_actions, [])
        |> Enum.map(&normalize_client_action/1),
      changes:
        action
        |> Map.get(:changes, [])
        |> Enum.map(&normalize_change/1)
    }
  end

  defp normalize_client_action(%{} = action) do
    if AshUi.EventBinding.client_action?(action) do
      Map.put(
        action,
        :opts,
        Enum.into(Map.get(action, :opts, %{}), %{}, fn {key, value} ->
          {key, ExprCompiler.compile!(value)}
        end)
      )
    else
      raise ArgumentError, "expected client action, got: #{inspect(action)}"
    end
  end

  defp normalize_action_type(%{type: nil, name: :create}), do: :create
  defp normalize_action_type(%{type: nil, name: :update}), do: :update
  defp normalize_action_type(%{type: nil, name: :destroy}), do: :destroy
  defp normalize_action_type(%{type: nil}), do: :update
  defp normalize_action_type(%{type: type}), do: type

  defp normalize_change(%{kind: :set_attribute, field: field, expr: expr}) do
    %{kind: :set_attribute, field: field, expr: ExprCompiler.compile!(expr)}
  end

  defp normalize_change(%{module: module, opts: opts}) when is_atom(module) and is_map(opts) do
    %{
      module: module,
      opts:
        Enum.into(opts, %{}, fn
          {key, {:_arg, name}} when is_atom(name) -> {key, {:_arg, name}}
          {key, value} -> {key, value}
        end)
    }
  end

  defp normalize_change(other) do
    raise ArgumentError, "unsupported action change metadata: #{inspect(other)}"
  end

  defp normalize_calculation(calculation) do
    expr = Map.get(calculation, :expr)
    compiled_expr = if is_nil(expr), do: nil, else: ExprCompiler.compile!(expr)

    %{
      name: Map.fetch!(calculation, :name),
      type: normalize_blueprint_type(Map.fetch!(calculation, :type)),
      constraints: Map.get(calculation, :constraints, []),
      calculation:
        normalize_calculation_module(Map.get(calculation, :calculation), compiled_expr),
      expr: compiled_expr,
      allow_nil?: Map.get(calculation, :allow_nil?, true)
    }
  end

  defp render_tree_calculation?(%{type: AshUi.Type.RenderTree, expr: %Compiled{}}),
    do: true

  defp render_tree_calculation?(_calculation), do: false

  defp view_from_calculations(calculations, name) do
    calculations
    |> Enum.find(&(&1.name == name and render_tree_calculation?(&1)))
    |> case do
      %{expr: %Compiled{} = expr} -> AshUi.ViewConstructor.lower(expr)
      _other -> nil
    end
  end

  defp normalize_calculation_module(nil, _compiled_expr), do: nil

  defp normalize_calculation_module(other, _compiled_expr), do: other

  defp normalize_relationship(relationship) do
    destination = Map.fetch!(relationship, :destination)

    {destination_kind, compiled_destination} =
      normalize_resource_ref!(destination, "relationship destination")

    %{
      name: Map.fetch!(relationship, :name),
      type: Map.fetch!(relationship, :type),
      destination: compiled_destination,
      destination_kind: destination_kind,
      destination_resource: nil,
      source_attribute: relationship_source_attribute(relationship),
      destination_attribute: relationship_destination_attribute(relationship),
      define_attribute?: relationship_define_attribute?(relationship),
      attribute_type: relationship_attribute_type(relationship),
      allow_nil?: Map.get(relationship, :allow_nil?),
      read_action: Map.get(relationship, :read_action),
      filter: Map.get(relationship, :filter),
      sort: Map.get(relationship, :sort),
      limit: Map.get(relationship, :limit),
      offset: Map.get(relationship, :offset),
      no_attributes?: Map.get(relationship, :no_attributes?, false),
      required_parent_attrs:
        Map.get(
          relationship,
          :required_parent_attrs,
          parent_attrs_from_filter(Map.get(relationship, :filter))
        )
    }
  end

  defp normalize_config(config, _data_layer) when is_map(config) do
    %{
      strict_expressions?:
        normalize_strict_expressions(Map.get(config, :strict_expressions?, :strict)),
      stylesheets: Map.get(config, :stylesheets, [])
    }
  end

  defp finalize_expression_calls!(%ResourceBlueprint{} = resource, module) do
    ExprCompiler.finalize_calls!(resource,
      strict_calls?: resource.strict_expressions? != :off,
      dsl_module: module,
      dsl_path: [:ash_ui]
    )
  end

  defp normalize_strict_expressions(mode) when mode in [:off, :warn, :strict], do: mode

  defp normalize_strict_expressions(other) do
    raise ArgumentError,
          "strict_expressions? must be :off, :warn, or :strict, got: #{inspect(other)}"
  end

  defp normalize_route(route) do
    params =
      route
      |> Map.get(:params, [])
      |> Enum.map(fn param ->
        %{
          name: Map.fetch!(param, :name),
          type: Map.fetch!(param, :type),
          default: Map.get(param, :default),
          constraints: Map.get(param, :constraints, [])
        }
      end)
      |> Enum.sort_by(& &1.name)

    states =
      route
      |> Map.get(:states, [])
      |> Enum.map(fn state ->
        %{
          name: Map.fetch!(state, :name),
          type: Map.fetch!(state, :type),
          param: Map.fetch!(state, :param),
          query: Map.get(state, :query),
          constraints: Map.get(state, :constraints, []),
          default: Map.get(state, :default)
        }
      end)
      |> Enum.sort_by(& &1.name)

    route_queries =
      route
      |> Map.get(:queries, [])
      |> Enum.map(fn query ->
        %{
          name: Map.fetch!(query, :name),
          type: Map.get(query, :type),
          default: Map.get(query, :default)
        }
      end)

    inferred_queries =
      states
      |> Enum.filter(& &1.query)
      |> Enum.map(fn state -> %{name: state.query, default: state.default} end)

    %{
      params: params,
      queries:
        (route_queries ++ inferred_queries)
        |> Enum.uniq_by(& &1.name)
        |> Enum.sort_by(& &1.name),
      states: states
    }
  end

  defp append_attribute_route_states(route, attributes) do
    attribute_states =
      attributes
      |> Enum.flat_map(fn
        %{route: nil} ->
          []

        %{name: name, type: type, route: route, default: default} ->
          [normalize_attribute_route(route, name, type, default)]

        _other ->
          []
      end)

    Map.update(route, :states, attribute_states, fn states ->
      (states ++ attribute_states)
      |> Enum.uniq_by(& &1.name)
    end)
  end

  defp relationship_source_attribute(%{type: :belongs_to, name: name} = relationship) do
    Map.get(relationship, :source_attribute, :"#{name}_id")
  end

  defp relationship_source_attribute(relationship), do: Map.get(relationship, :source_attribute)

  defp relationship_destination_attribute(%{type: :belongs_to} = relationship) do
    Map.get(relationship, :destination_attribute, :id)
  end

  defp relationship_destination_attribute(relationship),
    do: Map.get(relationship, :destination_attribute)

  defp relationship_define_attribute?(%{type: :belongs_to} = relationship) do
    Map.get(relationship, :define_attribute?, true)
  end

  defp relationship_define_attribute?(relationship), do: Map.get(relationship, :define_attribute?)

  defp relationship_attribute_type(%{type: :belongs_to} = relationship) do
    relationship
    |> Map.get(:attribute_type, :uuid)
    |> normalize_optional_blueprint_type()
  end

  defp relationship_attribute_type(relationship),
    do: normalize_optional_blueprint_type(Map.get(relationship, :attribute_type))

  defp parent_attrs_from_filter(filter) do
    filter
    |> do_parent_attrs_from_filter(MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp do_parent_attrs_from_filter(%Ash.Query.Parent{expr: {:_ref, [], attr}}, acc)
       when is_atom(attr),
       do: MapSet.put(acc, attr)

  defp do_parent_attrs_from_filter(%Ash.Query.Parent{expr: %Ash.Query.Ref{attribute: attr}}, acc)
       when is_atom(attr),
       do: MapSet.put(acc, attr)

  defp do_parent_attrs_from_filter(%Ash.Query.Parent{expr: attr}, acc) when is_atom(attr),
    do: MapSet.put(acc, attr)

  defp do_parent_attrs_from_filter({:_parent, [], {:_ref, [], attr}}, acc) when is_atom(attr),
    do: MapSet.put(acc, attr)

  defp do_parent_attrs_from_filter({:_parent, [], attr}, acc) when is_atom(attr),
    do: MapSet.put(acc, attr)

  defp do_parent_attrs_from_filter(%_{} = struct, acc) do
    struct
    |> Map.from_struct()
    |> do_parent_attrs_from_filter(acc)
  end

  defp do_parent_attrs_from_filter(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {key, value}, next_acc ->
      value
      |> do_parent_attrs_from_filter(do_parent_attrs_from_filter(key, next_acc))
    end)
  end

  defp do_parent_attrs_from_filter(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &do_parent_attrs_from_filter/2)
  end

  defp do_parent_attrs_from_filter(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> do_parent_attrs_from_filter(acc)
  end

  defp do_parent_attrs_from_filter(_other, acc), do: acc

  defp normalize_optional_view(nil), do: nil

  defp normalize_optional_view(view),
    do: AshUi.ViewConstructor.lower(view)

  defp resource_metadata({:static, module}) when is_atom(module) do
    resource_metadata(module)
  end

  defp resource_metadata(module) when is_atom(module) do
    %{
      module: module,
      domain: resource_domain(module),
      extensions: resource_extensions(module),
      data_layer: resource_data_layer(module)
    }
  end

  defp resource_metadata(_source) do
    %{module: nil, domain: nil, extensions: [], data_layer: nil}
  end

  defp resource_domain(module) do
    Ash.Resource.Info.domain(module)
  rescue
    error in [ArgumentError, UndefinedFunctionError] ->
      _ = error
      nil
  end

  defp resource_extensions(module) do
    Spark.extensions(module)
  rescue
    error in [ArgumentError, UndefinedFunctionError, Spark.Error.DslError] ->
      _ = error
      []
  end

  defp resource_data_layer(module) do
    Ash.Resource.Info.data_layer(module)
  rescue
    error in [ArgumentError, UndefinedFunctionError] ->
      _ = error
      nil
  end

  defp normalize_resource_ref!(source, label) do
    case source do
      module when is_atom(module) ->
        {:static, module}

      {module, function_name}
      when is_atom(module) and is_atom(function_name) ->
        {:interface, {:interface, module, function_name}}

      {:interface, module, function_name}
      when is_atom(module) and is_atom(function_name) ->
        {:interface, {:interface, module, function_name}}

      other ->
        raise ArgumentError, "unsupported #{label}: #{inspect(other)}"
    end
  end

  defp normalize_blueprint_type(type) when is_atom(type) do
    case Enum.find(Ash.Type.short_names(), fn {_short_name, module} -> module == type end) do
      {short_name, _module} -> short_name
      nil -> type
    end
  end

  defp normalize_blueprint_type(type), do: type
  defp normalize_optional_blueprint_type(nil), do: nil
  defp normalize_optional_blueprint_type(type), do: normalize_blueprint_type(type)

  defp ensure_blueprint_module!(module) when is_atom(module) do
    _ = Code.ensure_compiled(module)

    if function_exported?(module, :spark_is, 0) and
         Enum.member?(Spark.extensions(module), AshUi) do
      :ok
    else
      raise ArgumentError,
            "expected a static AshUi module using extensions: [AshUi], got: #{inspect(module)}"
    end
  rescue
    error in [ArgumentError, UndefinedFunctionError, Spark.Error.DslError] ->
      _ = error

      raise ArgumentError,
            "expected a static AshUi module using extensions: [AshUi], got: #{inspect(module)}"
  end

  defp ensure_blueprint_dsl_state!(dsl_state, module)
       when is_map(dsl_state) and is_atom(module) do
    extensions = Transformer.get_persisted(dsl_state, :extensions, [])

    if Enum.member?(extensions, AshUi) do
      :ok
    else
      raise ArgumentError,
            "expected AshUi DSL state for a static module using extensions: [AshUi], got: #{inspect(module)}"
    end
  end

  defp unwrap_ash_calculation({Ash.Resource.Calculation.Expression, opts}) when is_list(opts) do
    Keyword.fetch!(opts, :expr)
  end

  defp unwrap_ash_calculation({AshUi.ExportCalculation, opts}) when is_list(opts) do
    Keyword.get(opts, :expr)
  end

  defp unwrap_ash_calculation({AshUi.ViewCalculation, opts}) when is_list(opts) do
    Keyword.get(opts, :expr)
  end

  defp unwrap_ash_calculation(_other), do: nil
end
