defmodule AshUi.Expr.Scope do
  @moduledoc false

  defstruct [
    :runtime,
    :path,
    :record,
    :state,
    :resource,
    :ash_resource_module,
    :helper_module,
    :actor,
    :tenant,
    :changeset,
    args: %{},
    route: %{},
    route_params: %{},
    query_params: %{},
    context: %{},
    host_context: %{},
    item_bindings: %{},
    index_bindings: %{},
    props: %{},
    dom: %{},
    result: nil,
    errors: [],
    all_errors: [],
    part_ids: %{}
  ]

  @type t :: %__MODULE__{
          runtime: nil,
          path: [term()],
          record: term(),
          state: term(),
          resource: module() | term() | nil,
          ash_resource_module: module() | nil,
          helper_module: module() | nil,
          actor: term(),
          tenant: term(),
          changeset: term(),
          args: map(),
          route: map(),
          route_params: map(),
          query_params: map(),
          context: map(),
          host_context: map(),
          item_bindings: map(),
          index_bindings: map(),
          props: map(),
          dom: map(),
          result: term(),
          errors: list(),
          part_ids: map()
        }

  def new(record, params, opts \\ [])

  def new(record, params, opts) when is_map(params) and is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    new(record, params, opts)
  end

  def new(record, params, opts) when is_map(params) and is_map(opts) do
    runtime = Map.get(opts, :runtime)
    path = Map.get(opts, :path, [])
    context = opts |> Map.get(:context, %{}) |> Map.new()
    resource = Map.get(opts, :resource)
    ash_resource_module = Map.get(opts, :ash_resource_module, resource)
    route = Map.get(opts, :route, Map.get(context, :route, %{}))
    errors = Map.get(opts, :errors, [])

    %__MODULE__{
      runtime: runtime,
      path: path,
      record: record,
      state: record,
      resource: resource,
      ash_resource_module: ash_resource_module,
      helper_module: Map.get(opts, :helper_module, ash_resource_module),
      actor: Map.get(opts, :actor),
      tenant: Map.get(opts, :tenant),
      changeset: Map.get(opts, :changeset),
      args: params,
      route: route || %{},
      route_params:
        Map.get(
          opts,
          :route_params,
          lookup(route || %{}, :path_params) || lookup(route || %{}, "path_params") || %{}
        ),
      query_params: Map.get(opts, :query_params, %{}),
      context: runtime_context(context, runtime, path, Map.get(opts, :props)),
      host_context: Map.get(opts, :host_context, %{}),
      item_bindings: Map.get(opts, :item_bindings, %{}),
      index_bindings: Map.get(opts, :index_bindings, %{}),
      props: Map.get(opts, :props, params),
      dom: Map.get(opts, :dom, %{}),
      result: Map.get(opts, :command_result),
      errors: errors,
      all_errors: Map.get(opts, :__bp_all_errors__, errors),
      part_ids: Map.get(opts, :part_ids, %{})
    }
  end

  def for_eval(%__MODULE__{} = base, record, params, opts)
      when is_map(params) and is_list(opts) do
    opts = opts |> Enum.reverse() |> Map.new()
    for_eval(base, record, params, opts)
  end

  def for_eval(%__MODULE__{} = base, record, params, opts)
      when is_map(params) and is_map(opts) do
    runtime = Map.get(opts, :runtime, base.runtime)
    path = Map.get(opts, :path, base.path)
    props = Map.get(opts, :props, params)
    errors = Map.get(opts, :errors, base.errors)

    context =
      opts
      |> Map.get(:context, base.context)
      |> runtime_context(runtime, path, props)

    %__MODULE__{
      base
      | runtime: runtime,
        path: path,
        record: record,
        state: record,
        resource: Map.get(opts, :resource, base.resource),
        ash_resource_module: Map.get(opts, :ash_resource_module, base.ash_resource_module),
        helper_module: Map.get(opts, :helper_module, base.helper_module),
        actor: Map.get(opts, :actor, base.actor),
        tenant: Map.get(opts, :tenant, base.tenant),
        changeset: Map.get(opts, :changeset, base.changeset),
        args: params,
        route: Map.get(opts, :route, base.route),
        route_params: Map.get(opts, :route_params, base.route_params),
        query_params: Map.get(opts, :query_params, base.query_params),
        context: context,
        host_context: Map.get(opts, :host_context, base.host_context),
        item_bindings: Map.get(opts, :item_bindings, base.item_bindings),
        index_bindings: Map.get(opts, :index_bindings, base.index_bindings),
        props: props,
        dom: Map.get(opts, :dom, base.dom),
        result: Map.get(opts, :command_result, base.result),
        errors: errors,
        all_errors: Map.get(opts, :__bp_all_errors__, Map.get(opts, :errors, base.all_errors)),
        part_ids: Map.get(opts, :part_ids, base.part_ids)
    }
  end

  defp runtime_context(context, runtime, path, props) do
    context
    |> maybe_put(:__blueprint_runtime__, runtime)
    |> maybe_put(:__blueprint_path__, path)
    |> maybe_put(:__blueprint_props__, props)
  end

  defp maybe_put(context, _key, nil), do: context
  defp maybe_put(context, key, value), do: Map.put(context, key, value)

  defp lookup(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp lookup(_other, _key), do: nil
end
