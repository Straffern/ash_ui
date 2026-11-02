defmodule AshUi.Runtime.Rendering do
  @moduledoc false

  alias AshUi.ResourceBlueprint, as: Resource

  def render_view(resource_or_runtime, record_or_path \\ [], params \\ %{}, opts \\ [])

  def render_view(%Resource{} = resource, record, params, opts)
      when is_map(params) and is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    render_view(resource, record, params, opts)
  end

  def render_view(%Resource{} = resource, record, params, opts)
      when is_map(params) and is_map(opts) do
    opts =
      opts
      |> Map.put_new(:session_id, session_id(record))
      |> put_resource_context(resource)
      |> Map.put(
        :action_client_actions_by_part,
        AshUi.Runtime.ViewRender.action_client_actions_by_part(resource)
      )
      |> AshUi.Runtime.ViewRender.put_grouped_client_opts()
      |> then(fn opts ->
        AshUi.Runtime.ViewRender.put_error_scope(
          opts,
          Map.get(opts, :__bp_error_path__, [])
        )
      end)
      |> AshUi.Runtime.ViewRender.put_expr_scope_base(record, params)

    render_tree = AshUi.Patch.Compiler.stamp_addresses(resource.view)

    case render_tree do
      nil ->
        {:ok, nil}

      %{kind: :attached_view} = view ->
        AshUi.Runtime.ViewRender.render_attached_view(
          resource,
          view,
          record,
          params,
          opts
        )

      view ->
        AshUi.Runtime.ViewRender.render_view_node(resource, view, record, params, opts)
    end
  end

  def render_tree(resource_or_runtime, record_or_path \\ [], params \\ %{}, opts \\ [])

  def render_tree(%Resource{} = resource, record, params, opts)
      when is_map(params) and is_list(opts) do
    render_opts = opts |> Enum.reverse() |> Map.new()

    with {:ok, view} <- render_view(resource, record, params, render_opts),
         {:ok, tree} <- AshUi.RenderTree.render(view, opts) do
      {:ok, tree}
    end
  end

  defp put_resource_context(opts, %Resource{} = resource) do
    context =
      opts
      |> Map.get(:context, %{})
      |> case do
        context when is_map(context) -> context
        _other -> %{}
      end
      |> Map.put(:__blueprint_resource__, resource)

    Map.put(opts, :context, context)
  end

  defp session_id(%{session_id: session_id}), do: session_id
  defp session_id(_record), do: nil
end
