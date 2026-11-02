defmodule AshUi.Runtime.ResourceInfo do
  @moduledoc false

  alias AshUi.ResourceBlueprint, as: Resource

  def runtime_ash_resource_module(%Resource{module: module}, _fallback)
      when is_atom(module) and not is_nil(module) do
    module
  end

  def runtime_ash_resource_module(_resource, fallback) do
    fallback
  end

  def render_tree_for_record(%module{} = record, opts) when is_atom(module) do
    resource = compiled_resource(module)

    opts =
      opts |> Keyword.put(:ash_resource_module, module) |> Keyword.put(:helper_module, module)

    with {:ok, view} <- AshUi.Runtime.Rendering.render_view(resource, record, %{}, opts) do
      AshUi.RenderTree.render(view, opts)
    end
  end

  def compiled_resource(module) when is_atom(module) do
    AshUi.Compiled.resource!(module)
  end

  def static_blueprint_module?(module) when is_atom(module) do
    AshUi.Compiled.resource_target_module?(module)
  rescue
    # broad rescue: runtime module probing treats non-blueprint modules as false.
    _error -> false
  end
end
