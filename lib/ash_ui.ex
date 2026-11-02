defmodule AshUi do
  @moduledoc """
  Static AshUi extension and runtime surface.

  AshUi page resources are defined as normal `Ash.Resource` modules with
  `extensions: [AshUi]`, compiled through Spark/Ash, and consumed through
  persisted compile-time contracts at runtime.

  Application-authored state, reads, and behavior remain ordinary Ash
  attributes, relationships, calculations, and actions.
  """

  alias Spark.Error.DslError

  use Spark.Dsl.Extension,
    sections: AshUi.Dsl.sections(),
    transformers: [AshUi.Transformers.PersistStaticBlueprint],
    imports: [
      AshUi.ActionEffects,
      AshUi.Attributes,
      AshUi.Expr
    ]

  @type definition_input :: module()

  @spec compile!(definition_input(), keyword()) :: AshUi.ResourceBlueprint.t()
  def compile!(input, opts \\ [])

  def compile!(module, _opts) when is_atom(module),
    do: AshUi.Compiled.resource!(module)

  def compile!(input, _opts) do
    raise ArgumentError,
          "AshUi.compile!/2 accepts only static AshUi modules using extensions: [AshUi], got: #{inspect(input)}"
  end

  @doc """
  Builds the record a `render(Child, input)` child renders from — the ONE
  public construction path hosts use: an embedded child casts its input
  through its create action (instances pass through untouched); a
  store-backed child resolves its mounted row.
  """
  @spec build_child_record(module(), term(), keyword()) :: {:ok, struct()} | {:error, term()}
  def build_child_record(resource, input, opts \\ []) when is_atom(resource) do
    AshUi.Runtime.ResourceComponentRender.build_resource_component_record(
      resource,
      input,
      opts
    )
  end

  @doc """
  The `:view` calculation's derived load statement — the relationships and
  nested loads the view reads. Hosts load records through this before any
  render; it is the same dependency set `Ash.calculate(record, :view)`
  loads through the calculation's `load/3`.
  """
  @spec view_load(module(), atom()) :: list()
  def view_load(resource, view \\ :view) when is_atom(resource) do
    case AshUi.Compiled.view_exprs(resource) do
      %{^view => compiled} = exprs ->
        AshUi.ViewConstructor.load_spec(compiled, exprs, resource)

      _other ->
        []
    end
  end

  @doc false
  @spec expression_path(term(), keyword()) :: list() | nil
  def expression_path(expression, opts \\ []) do
    AshUi.Runtime.ViewRender.expression_path(expression, opts)
  end

  @doc false
  # Carries loaded values from `old` onto `new` wherever `new` still holds
  # `%Ash.NotLoaded{}` — the merge bridges use so a narrowed post-dispatch
  # reload never hands the renderer an unloaded view dependency.
  @spec preserve_loaded_values(struct(), struct()) :: struct()
  def preserve_loaded_values(%_{} = old, %_{} = new),
    do: preserve_unselected_loaded_values(old, new)

  @doc false
  # A root-row notification does not invalidate an ordinary relationship when
  # its source key is unchanged. Keep those already-loaded branches so the
  # bridge can recalculate the root view without re-reading every child row.
  # Filtered, manual, and attribute-less relationships remain conservative:
  # their membership may depend on more than the declared source key.
  @spec preserve_loaded_relationships(struct(), struct()) :: struct()
  def preserve_loaded_relationships(%resource{} = old, %resource{} = new) do
    Enum.reduce(Ash.Resource.Info.relationships(resource), new, fn relationship, acc ->
      source_attribute = Map.get(relationship, :source_attribute)
      old_value = Map.get(old, relationship.name)
      new_value = Map.get(acc, relationship.name)

      if match?(%Ash.NotLoaded{}, new_value) and
           not match?(%Ash.NotLoaded{}, old_value) and
           is_atom(source_attribute) and
           Map.get(old, source_attribute) == Map.get(new, source_attribute) and
           Map.get(relationship, :filter) in [nil, []] and
           is_nil(Map.get(relationship, :manual)) and
           not Map.get(relationship, :no_attributes?, false) do
        Map.put(acc, relationship.name, old_value)
      else
        acc
      end
    end)
  end

  @doc false
  # The top-level view dependencies whose value can change when the given root
  # attributes change, per the declaration-derived dependency index in
  # `AshUi.Reload` (the canonical O(1) dispatch reload policy).
  @spec dependent_view_roots(module(), [atom()]) :: [atom()]
  def dependent_view_roots(resource, changed_attributes),
    do: AshUi.Reload.dependent_roots_for_attributes(resource, changed_attributes)

  @doc """
  The original Ash error objects of a failed dispatch, as a flat list —
  the public error-surface contract for bridge adapters.
  """
  def dispatch_errors(reason) do
    reason
    |> AshUi.Runtime.Errors.normalize_invoke_error()
    |> AshUi.Runtime.Errors.list()
  end

  @doc """
  Formats one original dispatch error for a host-owned page error surface.

  Field errors include their field name; fieldless errors preserve the
  user-facing Ash message.
  """
  @spec dispatch_error_message(term()) :: String.t()
  def dispatch_error_message(error) do
    message = AshUi.Runtime.Errors.message(error)

    case AshUi.Runtime.Errors.field(error) do
      nil -> message
      field -> "#{field}: #{message}"
    end
  end

  @doc false
  @spec errors_at_path(term(), list()) :: list()
  def errors_at_path(errors, path) do
    AshUi.Runtime.ViewRender.errors_at_path(errors, path)
  end

  @doc """
  Reloads a resource through its declared session identity.

  Entity UI resources do not need a synthetic primary key: the ordinary Ash
  identity containing `:session_id` is their stable lookup contract. Resources
  without such an identity fall back to their primary key.
  """
  @spec reload(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def reload(%resource{} = record, opts \\ []) do
    identity =
      Enum.find(Ash.Resource.Info.identities(resource), fn identity ->
        :session_id in List.wrap(identity.keys)
      end)

    keys =
      case identity do
        %{keys: keys} -> List.wrap(keys)
        nil -> Ash.Resource.Info.primary_key(resource)
      end

    identifier = Map.new(keys, &{&1, Map.get(record, &1)})
    opts = Keyword.put_new(opts, :domain, Ash.Resource.Info.domain(resource) || AshDomainFallback)

    case Ash.get(resource, identifier, opts) do
      {:ok, nil} ->
        error = Ash.Error.Query.NotFound.exception(resource: resource, primary_key: identifier)
        {:error, Ash.Error.to_error_class(error)}

      result ->
        result
    end
  end

  @doc """
  Reloads exactly one relationship path on an already-loaded record.

  Notification adapters use this when their compile-derived subscription
  identifies the affected relationship. `:root` retains the ordinary durable
  row reload contract; a path such as `[:artist, :albums]` refreshes only that
  relationship branch and preserves all unrelated loaded view fields.
  """
  @spec reload_scope(struct(), :root | [atom()], keyword()) ::
          {:ok, struct()} | {:error, term()}
  def reload_scope(%_{} = record, :root, opts), do: reload(record, opts)

  def reload_scope(%_{} = record, [relationship | _rest] = path, opts)
      when is_atom(relationship) do
    reload_dependencies(record, [path], opts)
  end

  @doc false
  @spec reload_dependencies(struct(), [[atom()]], keyword()) ::
          {:ok, struct()} | {:error, term()}
  def reload_dependencies(%resource{} = record, paths, opts) when is_list(paths) do
    # A data change along a relationship path also invalidates every derived
    # root (calculation/aggregate) whose declared dependencies traverse it —
    # reload the changed relationship first, then recompute those roots from
    # the already-loaded sibling values. Loading both in one Ash.load call
    # would re-read every relationship dependency of a flattened-rows calc.
    paths = Enum.uniq(paths)

    dependent_roots =
      AshUi.Reload.dependent_roots_for_paths(resource, paths)

    view_load = view_load(resource)

    result =
      case loaded_branch_reload(record, view_load, paths, opts) do
        {:ok, loaded} -> {:ok, loaded}
        :root -> reload_dependencies_from_root(record, view_load, paths, opts)
        {:error, _reason} = error -> error
      end

    with {:ok, loaded} <- result do
      recalculate_dependent_roots(loaded, dependent_roots, view_load, opts)
    end
  end

  defp recalculate_dependent_roots(record, [], _view_load, _opts), do: {:ok, record}

  defp recalculate_dependent_roots(record, roots, view_load, opts) do
    Enum.reduce_while(roots, {:ok, record}, fn root, {:ok, loaded} ->
      if Ash.Resource.Info.calculation(loaded.__struct__, root) do
        unloaded =
          Map.put(loaded, root, %Ash.NotLoaded{
            field: root,
            type: :calculation,
            resource: loaded.__struct__
          })

        case Ash.calculate(unloaded, root, Keyword.put(opts, :reuse_values?, true)) do
          {:ok, value} -> {:cont, {:ok, Map.put(loaded, root, value)}}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        case reload_dependencies_from_root(loaded, view_load, [[root]], opts) do
          {:ok, reloaded} -> {:cont, {:ok, reloaded}}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    end)
  end

  # A nested notification already has the relationship owner in the session
  # row. Entering Ash.load at that owner avoids re-reading the page -> owner
  # edge merely to refresh a descendant. Multiple paths under the same owner
  # are combined into one load; paths spanning roots retain the general root
  # loader below.
  defp loaded_branch_reload(record, view_load, paths, opts) do
    with [[field | _rest] | _] <- paths,
         true <- Enum.all?(paths, &match?([^field, _ | _], &1)),
         value when not is_nil(value) <- Map.get(record, field),
         false <- match?(%Ash.NotLoaded{}, value),
         nested when is_list(nested) <- nested_load_for(view_load, field) do
      load =
        paths
        |> Enum.flat_map(fn [_field | rest] ->
          select_scoped_load(nested, rest) || nested_relationship_load(rest)
        end)
        |> Enum.uniq()

      branch_opts = Keyword.put(opts, :domain, loaded_value_domain(value, record.__struct__))

      # These paths were selected by an explicit data invalidation. Reusing a
      # loaded calculation on an existing relationship row would preserve the
      # stale value even though the relationship itself was read again.
      case Ash.load(value, load, Keyword.put(branch_opts, :reuse_values?, false)) do
        {:ok, loaded} ->
          with {:ok, loaded} <-
                 hydrate_new_relationship_records(
                   value,
                   loaded,
                   nested,
                   Enum.map(paths, &tl/1),
                   branch_opts
                 ) do
            {:ok, Map.put(record, field, preserve_unselected_loaded_values(value, loaded))}
          end

        {:error, _reason} = error ->
          error
      end
    else
      _cannot_enter_loaded_owner -> :root
    end
  end

  defp reload_dependencies_from_root(record, view_load, paths, opts) do
    load =
      paths
      |> Enum.flat_map(fn path ->
        select_scoped_load(view_load, path) || nested_relationship_load(path)
      end)

    # Reload every selected value, including calculations already present on
    # existing relationship rows. Unselected roots are restored below.
    case Ash.load(record, load, Keyword.put(opts, :reuse_values?, false)) do
      {:ok, loaded} ->
        with {:ok, loaded} <-
               hydrate_new_relationship_records(record, loaded, view_load, paths, opts) do
          {:ok, preserve_unselected_loaded_values(record, loaded)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp hydrate_new_relationship_records(old, new, view_load, paths, opts) do
    paths
    |> Enum.filter(&match?([field] when is_atom(field), &1))
    |> Enum.reduce_while({:ok, new}, fn [field], {:ok, acc} ->
      case nested_load_for(view_load, field) do
        nil ->
          {:cont, {:ok, acc}}

        [] ->
          {:cont, {:ok, acc}}

        nested ->
          old_keys =
            old
            |> Map.get(field)
            |> List.wrap()
            |> Enum.with_index()
            |> MapSet.new(fn {value, index} -> loaded_value_key(value, index) end)

          children = acc |> Map.get(field) |> List.wrap()

          new_children =
            children
            |> Enum.with_index()
            |> Enum.reject(fn {value, index} ->
              MapSet.member?(old_keys, loaded_value_key(value, index))
            end)
            |> Enum.map(&elem(&1, 0))
            |> Enum.filter(&nested_load_missing?(&1, nested))

          if new_children == [] do
            {:cont, {:ok, acc}}
          else
            child_opts =
              Keyword.put(opts, :domain, loaded_value_domain(new_children, acc.__struct__))

            case Ash.load(new_children, nested, Keyword.put_new(child_opts, :reuse_values?, true)) do
              {:ok, hydrated} ->
                hydrated_by_key =
                  hydrated
                  |> Enum.with_index()
                  |> Map.new(fn {value, index} -> {loaded_value_key(value, index), value} end)

                children =
                  children
                  |> Enum.with_index()
                  |> Enum.map(fn {value, index} ->
                    Map.get(hydrated_by_key, loaded_value_key(value, index), value)
                  end)

                value = if is_list(Map.get(acc, field)), do: children, else: List.first(children)
                {:cont, {:ok, Map.put(acc, field, value)}}

              {:error, _reason} = error ->
                {:halt, error}
            end
          end
      end
    end)
  end

  defp nested_load_missing?(record, nested) when is_map(record) do
    nested
    |> List.wrap()
    |> Enum.any?(fn
      {field, _nested} -> match?(%Ash.NotLoaded{}, Map.get(record, field))
      field when is_atom(field) -> match?(%Ash.NotLoaded{}, Map.get(record, field))
      _other -> false
    end)
  end

  defp nested_load_missing?(_record, _nested), do: false

  defp nested_load_for(load, field) do
    load
    |> List.wrap()
    |> Enum.find_value(fn
      {^field, nested} -> List.wrap(nested)
      _other -> nil
    end)
  end

  defp loaded_value_domain([%resource{} | _rest], fallback),
    do:
      Ash.Resource.Info.domain(resource) || Ash.Resource.Info.domain(fallback) ||
        AshDomainFallback

  defp loaded_value_domain(%resource{}, fallback),
    do:
      Ash.Resource.Info.domain(resource) || Ash.Resource.Info.domain(fallback) ||
        AshDomainFallback

  defp loaded_value_domain(_value, fallback),
    do: Ash.Resource.Info.domain(fallback) || AshDomainFallback

  defp select_scoped_load(load, [field]) do
    load
    |> List.wrap()
    |> Enum.find_value(fn
      ^field -> [field]
      {^field, nested} -> [{field, nested}]
      _other -> nil
    end)
  end

  defp select_scoped_load(load, [field | rest]) do
    load
    |> List.wrap()
    |> Enum.find_value(fn
      {^field, nested} ->
        case select_scoped_load(nested, rest) do
          nil -> nil
          selected -> [{field, selected}]
        end

      _other ->
        nil
    end)
  end

  defp nested_relationship_load([relationship]), do: [relationship]

  defp nested_relationship_load([relationship | rest]) do
    [{relationship, nested_relationship_load(rest)}]
  end

  defp preserve_unselected_loaded_values(old, %Ash.NotLoaded{}), do: old

  # Equal terms have equal loads — nothing to preserve. This clause is what
  # keeps preservation O(changed): an action result carries its data record's
  # relationship lists through pointer-identical, and BEAM equality on an
  # identical term is O(1), so an untouched 10k-row transcript costs nothing
  # here instead of a full per-row keyed merge walk.
  defp preserve_unselected_loaded_values(old, new) when old == new, do: new

  defp preserve_unselected_loaded_values(%resource{} = old, %resource{} = new) do
    if Ash.Resource.Info.resource?(resource) do
      new
      |> Map.from_struct()
      |> Enum.reduce(new, fn
        {:__metadata__, _value}, acc ->
          acc

        {key, value}, acc ->
          Map.put(acc, key, preserve_unselected_loaded_values(Map.get(old, key), value))
      end)
    else
      # Typed value structs are opaque to Ash's load graph. Walking them as
      # resources makes any nested list attempt Spark/Ash introspection on
      # ordinary structs (for example a Workbench layout tree).
      new
    end
  end

  defp preserve_unselected_loaded_values(old, new) when is_list(old) and is_list(new) do
    old_by_key =
      old
      |> Enum.with_index()
      |> Map.new(fn {value, index} -> {loaded_value_key(value, index), value} end)

    new
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      case Map.fetch(old_by_key, loaded_value_key(value, index)) do
        {:ok, previous} -> preserve_unselected_loaded_values(previous, value)
        :error -> value
      end
    end)
  end

  defp preserve_unselected_loaded_values(old, new) when is_map(old) and is_map(new),
    do: Map.merge(old, new)

  defp preserve_unselected_loaded_values(_old, new), do: new

  defp loaded_value_key(%resource{} = record, _index) do
    if Ash.Resource.Info.resource?(resource) do
      values = Enum.map(Ash.Resource.Info.primary_key(resource), &Map.get(record, &1))
      {resource, values}
    else
      {:value, record}
    end
  end

  defp loaded_value_key(_value, index), do: {:index, index}

  @spec blueprint!(module()) :: map()
  def blueprint!(module) when is_atom(module) do
    AshUi.Compiled.blueprint!(module)
  end

  @spec verify_deferred!(module() | [module()]) :: :ok
  def verify_deferred!(modules) when is_list(modules) do
    Enum.each(modules, &verify_deferred!/1)
  end

  def verify_deferred!(module) when is_atom(module) do
    module
    |> AshUi.Compiled.deferred_checks()
    |> Enum.each(&run_deferred_check!/1)

    :ok
  end

  @spec render(module(), map(), keyword()) ::
          {:ok, AshUi.RenderTree.t()} | {:error, term()}
  @doc """
  Casts raw maps (an engine/boundary result) into a list of embedded
  value-resource structs — the ONE sanctioned way raw data enters a
  AshUi read model. Raises a located error naming the row index and
  the failing field, so shape drift surfaces at the boundary instead of
  as a nil deep in a view.

      {:ok, entries} = AshUi.cast_rows(TreeEntry, raw_maps)
      entries = AshUi.cast_rows!(TreeEntry, raw_maps)
  """
  def cast_rows(module, rows) when is_atom(module) and is_list(rows) do
    Ash.Type.cast_input({:array, module}, rows)
  end

  def cast_rows!(module, rows) when is_atom(module) and is_list(rows) do
    case cast_rows(module, rows) do
      {:ok, cast} ->
        cast

      {:error, reason} ->
        index =
          Enum.find_index(rows, fn row ->
            match?(:error, Ash.Type.cast_input(module, row)) or
              match?({:error, _}, Ash.Type.cast_input(module, row))
          end)

        raise ArgumentError,
              "cast_rows!(#{inspect(module)}) failed" <>
                if(index, do: " at row #{index}", else: "") <>
                ": #{inspect(reason)}"

      :error ->
        raise ArgumentError, "cast_rows!(#{inspect(module)}) failed: invalid rows"
    end
  end

  def render(resource, input, opts \\ [])
      when is_atom(resource) and is_map(input) and is_list(opts) do
    view = Keyword.get(opts, :view, :view)

    with {:ok, record} <- render_record(resource, input, opts) do
      compiled = AshUi.Runtime.ResourceInfo.compiled_resource(resource)

      compiled =
        case {view, AshUi.Compiled.view_exprs(resource)} do
          {:view, _exprs} ->
            compiled

          {_named, %{^view => expr}} ->
            %{compiled | view: AshUi.ViewConstructor.lower(expr)}

          _other ->
            nil
        end

      if compiled do
        AshUi.Runtime.Rendering.render_tree(compiled, record, %{}, opts)
      else
        {:error, {:unknown_view, resource, view}}
      end
    end
  end

  @spec render!(module(), map(), keyword()) :: AshUi.RenderTree.t()
  def render!(resource, input, opts \\ []) do
    case render(resource, input, opts) do
      {:ok, tree} ->
        tree

      {:error, reason} ->
        raise ArgumentError, "failed to render #{inspect(resource)}: #{inspect(reason)}"
    end
  end

  defp render_record(resource, input, opts) do
    cond do
      embedded_resource?(resource) ->
        action = Keyword.get(opts, :action, :create)

        record =
          resource
          |> Ash.Changeset.for_create(action, input,
            domain: Keyword.get(opts, :domain, AshUi.AshDomainFallback)
          )
          |> Ash.Changeset.apply_attributes()
          |> case do
            {:ok, record} ->
              record

            {:error, changeset} ->
              raise Ash.Error.to_error_class(changeset.errors, changeset: changeset)
          end

        {:ok, record}

      match?(%{__struct__: ^resource}, input) ->
        {:ok, input}

      true ->
        # Entity resources render policy-checked records, never bare maps —
        # load the row through its domain first (nested_ui_model.md).
        {:error,
         {:entity_render_requires_record, resource,
          "render/3 for a non-embedded resource takes a loaded record; " <>
            "read it through its domain code interface first"}}
    end
  rescue
    error -> {:error, error}
  end

  defp embedded_resource?(resource) when is_atom(resource) do
    (function_exported?(resource, :spark_is, 0) or
       (Code.ensure_loaded?(resource) and function_exported?(resource, :spark_is, 0))) and
      Ash.Resource.Info.embedded?(resource)
  rescue
    _error in [ArgumentError, UndefinedFunctionError] -> false
  end

  defp run_deferred_check!(%{kind: :read_interface} = check) do
    domain = Map.fetch!(check, :domain)
    interface = Map.fetch!(check, :interface)
    expected_action = Map.fetch!(check, :action)

    cond do
      not Code.ensure_loaded?(domain) ->
        raise_deferred_error(check, "deferred module #{inspect(domain)} is not loaded")

      true ->
        case deferred_read_interface_target(domain, interface) do
          {:ok, _resource, ^expected_action} ->
            :ok

          {:ok, resource, actual_action} ->
            raise_deferred_error(
              check,
              "read `#{inspect(Map.get(check, :read))}` resolves #{inspect(domain)}.#{interface}/0 to #{inspect(resource)}##{inspect(actual_action)}, not #{inspect(expected_action)}"
            )

          {:defer, module} ->
            raise_deferred_error(check, "deferred module #{inspect(module)} is not loaded")

          :error ->
            raise_deferred_error(
              check,
              "read `#{inspect(Map.get(check, :read))}` references unknown read interface #{inspect(domain)}.#{interface}/0"
            )
        end
    end
  end

  defp run_deferred_check!(%{kind: :relationship_destination, destination: destination} = check) do
    unless Code.ensure_loaded?(destination) do
      raise_deferred_error(check, "deferred module #{inspect(destination)} is not loaded")
    end
  end

  defp run_deferred_check!(%{} = check) do
    raise_deferred_error(check, Map.get(check, :message, "deferred check failed"))
  end

  defp deferred_read_interface_target(domain, interface) do
    domain
    |> Ash.Domain.Info.resource_references()
    |> Enum.reduce_while(:error, fn reference, acc ->
      case Enum.find(reference.definitions, &match?(%{name: ^interface}, &1)) do
        nil ->
          {:cont, acc}

        definition ->
          action_name = Map.get(definition, :action) || definition.name

          cond do
            not Code.ensure_loaded?(reference.resource) ->
              {:halt, {:defer, reference.resource}}

            match?(%{type: :read}, Ash.Resource.Info.action(reference.resource, action_name)) ->
              {:halt, {:ok, reference.resource, action_name}}

            true ->
              {:cont, acc}
          end
      end
    end)
  rescue
    error in [ArgumentError, UndefinedFunctionError] ->
      _ = error
      :error
  end

  defp raise_deferred_error(check, message) do
    raise DslError.exception(
            module: Map.fetch!(check, :module),
            path: Map.get(check, :path, []),
            message: message
          )
  end
end
