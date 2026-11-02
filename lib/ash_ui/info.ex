defmodule AshUi.Info do
  @moduledoc false

  alias Spark.Dsl.Extension

  @doc """
  Stylesheets declared LOCALLY on the resource via `ash_ui do stylesheets [...] end`.
  """
  def declared_stylesheets(module) when is_atom(module) do
    Extension.get_opt(module, [:ash_ui], :stylesheets, []) || []
  rescue
    _error in [ArgumentError, UndefinedFunctionError, Spark.Error.DslError] -> []
  end

  @doc """
  Stylesheets SUPPLIED by a substrate extension through the supplier seam
  (see `AshUi.Transformers.PersistStaticBlueprint`). `nil` means no
  substrate supplied a set; `[]` means a substrate supplied the empty set.
  """
  def supplied_stylesheets(module) when is_atom(module) do
    Extension.get_persisted(module, {:ash_ui, :supplied_stylesheets}, nil)
  rescue
    _error in [ArgumentError, UndefinedFunctionError, Spark.Error.DslError] -> nil
  end

  @doc """
  The EFFECTIVE stylesheets a routed resource serves and is coverage-verified
  against: the supplied set when a substrate supplied one, otherwise the
  locally declared set. The persisted effective list computed at compile time
  is preferred when present.
  """
  def stylesheets(module) when is_atom(module) do
    case Extension.get_persisted(module, :ash_ui_stylesheets, nil) do
      list when is_list(list) -> list
      _other -> effective_stylesheets(declared_stylesheets(module), supplied_stylesheets(module))
    end
  rescue
    _error in [ArgumentError, UndefinedFunctionError, Spark.Error.DslError] ->
      effective_stylesheets(declared_stylesheets(module), supplied_stylesheets(module))
  end

  @doc """
  Resolves the effective stylesheet set from a declared list and an optional
  supplied list. A supplied set (even empty) wins; otherwise the declared set.
  """
  def effective_stylesheets(declared, supplied)
  def effective_stylesheets(_declared, supplied) when is_list(supplied), do: supplied
  def effective_stylesheets(declared, _supplied), do: declared || []

  def dynamic_map_props(module_or_resource) do
    resource = AshUi.Compiled.resource!(module_or_resource)

    case Map.get(resource, :dynamic_map_props, []) do
      [] ->
        case collect_dynamic_map_props(resource) do
          [] when is_atom(module_or_resource) ->
            collect_dynamic_map_props_from_dsl(module_or_resource)

          dynamic_map_props ->
            dynamic_map_props
        end

      dynamic_map_props ->
        dynamic_map_props
    end
  end

  def client_drivers(module_or_resource) do
    module_or_resource
    |> AshUi.Compiled.resource!()
    |> Map.get(:client_drivers, [])
  end

  defp collect_dynamic_map_props(_resource), do: []
  defp collect_dynamic_map_props_from_dsl(_module), do: []
end
