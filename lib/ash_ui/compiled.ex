defmodule AshUi.Compiled do
  @moduledoc false

  alias AshUi.ResourceBlueprint
  alias Spark.Error.DslError

  @patch_table_variant_limit 16

  @spec resource!(module() | ResourceBlueprint.t()) :: ResourceBlueprint.t()
  def resource!(%ResourceBlueprint{} = resource), do: resource

  def resource!(module) when is_atom(module) do
    if lightweight_compiled_resource_module?(module) do
      module.compiled_resource()
      |> resource!()
    else
      hash = compiled_blueprint_hash(module)
      cache_key = resource_cache_key(module)

      case :persistent_term.get(cache_key, :__ash_ui_cache_miss__) do
        {^hash, %ResourceBlueprint{} = resource} ->
          resource

        _missing_or_stale ->
          stack = MapSet.new([module])

          resource =
            module
            |> persisted_resource!()
            |> materialize_resource_graph(stack)

          :persistent_term.put(cache_key, {hash, resource})
          resource
      end
    end
  end

  @spec deferred_checks(module() | ResourceBlueprint.t()) :: [map()]
  def deferred_checks(%ResourceBlueprint{} = resource),
    do: Map.get(resource, :deferred_checks, [])

  def deferred_checks(module) when is_atom(module) do
    ensure_static_blueprint_module!(module)

    module
    |> persisted_deferred_checks()
    |> List.wrap()
  end

  @spec view_exprs(module()) :: map()
  def view_exprs(module) when is_atom(module) do
    ensure_static_blueprint_module!(module)
    persisted_view_exprs(module) || %{}
  end

  @spec blueprint!(module() | map() | ResourceBlueprint.t()) :: map()
  def blueprint!(%ResourceBlueprint{} = resource), do: normalize_blueprint_term(resource)
  def blueprint!(blueprint) when is_map(blueprint), do: normalize_blueprint_term(blueprint)

  def blueprint!(module) when is_atom(module) do
    ensure_static_blueprint_module!(module)

    module
    |> persisted_blueprint_value()
    |> normalize_persisted_blueprint!(module)
  end

  # The ONE runtime patch-table memo (see Patch.Compiler.cached_table/3 —
  # the canonical API every target calls). A table is a pure function of
  # (blueprint, view, target, navigation routes). One stable term per
  # module/view stores the current blueprint hash and a bounded variant set,
  # so recompiles replace stale artifacts instead of leaking global terms.
  @spec cached_patch_table(module(), atom(), term(), (-> term())) :: term()
  def cached_patch_table(module, view, variant, build)
      when is_atom(module) and is_atom(view) and is_function(build, 0) do
    hash = compiled_blueprint_hash(module)
    key = {:ash_ui_patch_table_cache, module, view}

    case :persistent_term.get(key, :__ash_ui_cache_miss__) do
      {^hash, variants} when is_list(variants) ->
        case Enum.find(variants, fn {cached_variant, _table} -> cached_variant == variant end) do
          {_cached_variant, table} ->
            table

          nil ->
            table = build.()

            variants =
              [
                {variant, table}
                | Enum.reject(variants, fn {cached, _table} -> cached == variant end)
              ]
              |> Enum.take(@patch_table_variant_limit)

            :persistent_term.put(key, {hash, variants})
            table
        end

      _missing_or_stale ->
        table = build.()
        :persistent_term.put(key, {hash, [{variant, table}]})
        table
    end
  end

  # The reload-contract dependency index (AshUi.Reload) is a pure
  # function of the resource's declarations — memoized here with the other
  # compile-time contracts. The stable key's value carries the persisted
  # blueprint hash so recompiles replace stale entries in place.
  @spec reload_dependency_index(module()) :: list()
  def reload_dependency_index(module) when is_atom(module) do
    hash = compiled_blueprint_hash(module)
    key = {:ash_ui_reload_dependency_index, module}

    case :persistent_term.get(key, :__ash_ui_cache_miss__) do
      {^hash, index} when is_list(index) ->
        index

      _missing_or_stale ->
        index = AshUi.Reload.build_dependency_index(module)
        :persistent_term.put(key, {hash, index})
        index
    end
  end

  # The declaration-derived read set of one derived field
  # (AshUi.Reload.derived_reads/2) — the subscription side of the same
  # derivation. Dependency resources need not be AshUi resources, so the
  # entry is versioned by the resource module's own md5.
  @spec derived_reads(module(), atom()) :: list()
  def derived_reads(module, field) when is_atom(module) and is_atom(field) do
    version = module.module_info(:md5)
    key = {:ash_ui_derived_reads, module, field}

    case :persistent_term.get(key, :__ash_ui_cache_miss__) do
      {^version, reads} when is_list(reads) ->
        reads

      _missing_or_stale ->
        reads = AshUi.Reload.build_derived_reads(module, field)
        :persistent_term.put(key, {version, reads})
        reads
    end
  end

  @spec resource_target_module?(module()) :: boolean()
  def resource_target_module?(module) when is_atom(module) do
    static_blueprint_module?(module) or lightweight_compiled_resource_module?(module)
  end

  def resource_target_module?(_module), do: false

  defp persisted_resource!(module) when is_atom(module) do
    ensure_static_blueprint_module!(module)

    case persisted_compiled_resource(module) do
      %ResourceBlueprint{} = resource ->
        resource

      _other ->
        raise ArgumentError,
              "expected persisted compile-time AshUi resource data on static module #{inspect(module)}"
    end
  end

  defp normalize_blueprint_term(%Ash.Query.Not{expression: expression}) do
    %{not: normalize_blueprint_term(expression)}
  end

  defp normalize_blueprint_term(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_blueprint_term()
  end

  defp normalize_blueprint_term(map) when is_map(map) do
    map
    |> Map.delete(:source)
    |> Enum.into(%{}, fn {key, value} -> {key, normalize_blueprint_term(value)} end)
  end

  defp normalize_blueprint_term(list) when is_list(list),
    do: Enum.map(list, &normalize_blueprint_term/1)

  defp normalize_blueprint_term(other), do: other

  defp materialize_resource_graph(%ResourceBlueprint{} = resource, stack) do
    %{
      resource
      | relationships: Enum.map(resource.relationships, &materialize_relationship(&1, stack))
    }
  end

  defp materialize_relationship(
         %{destination_kind: :static, destination: module} = relationship,
         stack
       )
       when is_atom(module) and is_map_key(relationship, :destination_resource) do
    %{
      relationship
      | destination_resource:
          if(MapSet.member?(stack, module),
            do: nil,
            else:
              Map.get(relationship, :destination_resource) ||
                materialize_nested_resource(module, stack)
          )
    }
  end

  defp materialize_relationship(relationship, _stack), do: relationship

  defp materialize_nested_resource(module, stack) when is_atom(module) do
    cond do
      MapSet.member?(stack, module) ->
        nil

      not nested_blueprint_module?(module) ->
        nil

      true ->
        resource!(module, stack)
    end
  end

  defp resource!(module, stack) when is_atom(module) do
    module
    |> persisted_resource!()
    |> materialize_resource_graph(MapSet.put(stack, module))
  end

  defp nested_blueprint_module?(module) when is_atom(module) do
    static_blueprint_module?(module)
  rescue
    error in [ArgumentError, UndefinedFunctionError, DslError] ->
      _ = error
      false
  end

  defp static_blueprint_module?(module) when is_atom(module) do
    ensure_compiled?(module) and function_exported?(module, :spark_is, 0) and
      Enum.member?(Spark.extensions(module), AshUi)
  rescue
    error in [ArgumentError, UndefinedFunctionError, DslError] ->
      _ = error
      false
  end

  defp lightweight_compiled_resource_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :compiled_resource, 0)
  rescue
    error in [ArgumentError, UndefinedFunctionError] ->
      _ = error
      false
  end

  defp persisted_compiled_resource(module) when is_atom(module) do
    if ensure_compiled?(module) do
      Spark.Dsl.Extension.get_persisted(module, :ash_ui_compiled_resource)
    end
  rescue
    error in [ArgumentError, UndefinedFunctionError, DslError] ->
      _ = error
      nil
  end

  defp persisted_blueprint_value(module) when is_atom(module) do
    if ensure_compiled?(module) do
      Spark.Dsl.Extension.get_persisted(module, :ash_ui_compiled_blueprint)
    end
  rescue
    error in [ArgumentError, UndefinedFunctionError, Spark.Error.DslError] ->
      _ = error
      nil
  end

  defp persisted_deferred_checks(module) when is_atom(module) do
    if ensure_compiled?(module) do
      Spark.Dsl.Extension.get_persisted(module, :ash_ui_deferred_checks)
    end
  rescue
    error in [ArgumentError, UndefinedFunctionError, DslError] ->
      _ = error
      []
  end

  defp persisted_view_exprs(module) when is_atom(module) do
    if ensure_compiled?(module) do
      Spark.Dsl.Extension.get_persisted(module, :ash_ui_view_exprs)
    end
  rescue
    error in [ArgumentError, UndefinedFunctionError, DslError] ->
      _ = error
      nil
  end

  defp normalize_persisted_blueprint!(persisted_blueprint, _module)
       when is_map(persisted_blueprint) do
    normalize_blueprint_term(persisted_blueprint)
  end

  defp normalize_persisted_blueprint!(_other, module) do
    raise ArgumentError,
          "expected persisted compile-time AshUi data on static module #{inspect(module)}"
  end

  defp ensure_static_blueprint_module!(module) when is_atom(module) do
    ensure_compiled!(module)

    if static_blueprint_module?(module) do
      :ok
    else
      raise ArgumentError,
            "expected a static AshUi module using extensions: [AshUi], got: #{inspect(module)}"
    end
  end

  defp ensure_compiled!(module) when is_atom(module) do
    _ = Code.ensure_compiled(module)
    :ok
  end

  defp ensure_compiled?(module) when is_atom(module) do
    match?({:module, ^module}, Code.ensure_compiled(module))
  end

  defp ensure_compiled?(_module), do: false

  defp resource_cache_key(module) do
    {:ash_ui_compiled_resource, module}
  end

  defp compiled_blueprint_hash(module) when is_atom(module) do
    cond do
      function_exported?(module, :__ash_ui_blueprint_hash__, 0) ->
        apply(module, :__ash_ui_blueprint_hash__, [])

      is_binary(persisted_blueprint_hash(module)) ->
        persisted_blueprint_hash(module)

      true ->
        blueprint_hash(module)
    end
  rescue
    error in [ArgumentError, UndefinedFunctionError, DslError] ->
      _ = error
      blueprint_hash(module)
  end

  defp persisted_blueprint_hash(module) do
    if ensure_compiled?(module) do
      Spark.Dsl.Extension.get_persisted(module, :ash_ui_compiled_blueprint_hash)
    end
  rescue
    error in [ArgumentError, UndefinedFunctionError, DslError] ->
      _ = error
      nil
  end

  defp blueprint_hash(module) do
    module
    |> persisted_blueprint_value()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end
end
