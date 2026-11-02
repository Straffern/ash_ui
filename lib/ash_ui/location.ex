defmodule AshUi.Location do
  @moduledoc false

  @spec project(struct(), String.t(), keyword()) ::
          :unchanged | {:patch, String.t()} | {:navigate, String.t()}
  def project(record, current, opts \\ [])

  def project(%resource{} = record, current, opts) when is_binary(current) do
    with [_first | _rest] = routes <- routes(resource) do
      current_path = current |> String.split("?", parts: 2) |> hd()

      {_path_template, query_names} =
        Enum.find(routes, fn {template, _query} -> same_template?(current_path, template) end) ||
          hd(routes)

      case explicit(resource, record, opts) do
        location when is_binary(location) and location != current ->
          if Enum.any?(routes, fn {template, _query} -> same_template?(location, template) end),
            do: {:patch, location},
            else: {:navigate, location}

        location when is_binary(location) ->
          :unchanged

        nil ->
          target =
            current_path
            |> projected(query_names, resource, record)
            |> preserve_query_params(Keyword.get(opts, :preserve_query_params, %{}))

          if target == current, do: :unchanged, else: {:patch, target}
      end
    else
      _unrouted -> :unchanged
    end
  end

  def project(_record, _current, _opts), do: :unchanged

  def routes(resource) do
    if Code.ensure_loaded?(resource) do
      cond do
        function_exported?(resource, :__ash_ui_routes__, 0) ->
          resource.__ash_ui_routes__()

        function_exported?(resource, :__ash_ui_route__, 0) ->
          [resource.__ash_ui_route__()]

        true ->
          []
      end
    else
      []
    end
  end

  @doc false
  # resource-less walks (subtree dep collection) have no route universe
  def navigation_routes(nil), do: %{all: [], patch: []}

  def navigation_routes(resource) do
    own = resource |> routes() |> Enum.map(&elem(&1, 0))

    resources =
      case Ash.Resource.Info.domain(resource) do
        nil ->
          [resource]

        domain ->
          if Code.ensure_loaded?(domain),
            do: Ash.Domain.Info.resources(domain),
            else: [resource]
      end

    all =
      resources
      |> Enum.flat_map(&routes/1)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    %{all: all, patch: own}
  end

  @doc false
  def navigation_kind(%{all: all, patch: patch}, href) when is_binary(href) do
    cond do
      not String.starts_with?(href, "/") -> nil
      String.starts_with?(href, "//") -> nil
      Enum.any?(patch, &same_template?(href, &1)) -> :patch
      Enum.any?(all, &same_template?(href, &1)) -> :redirect
      true -> nil
    end
  end

  def navigation_kind(_routes, _href), do: nil

  def same_template?(target, path_template) do
    target_path = target |> String.split("?", parts: 2) |> hd() |> String.split("/", trim: true)
    template = String.split(path_template, "/", trim: true)

    length(target_path) == length(template) and
      template
      |> Enum.zip(target_path)
      |> Enum.all?(fn {template_segment, target_segment} ->
        String.starts_with?(template_segment, ":") or
          String.starts_with?(template_segment, "*") or
          template_segment == target_segment
      end)
  end

  defp explicit(resource, record, opts) do
    with true <- function_exported?(resource, :__ash_ui_route_location__, 0),
         %AshUi.Expr.Compiled{} = compiled <- resource.__ash_ui_route_location__(),
         location when is_binary(location) and location != "" <-
           AshUi.Expr.Eval.eval!(
             compiled,
             AshUi.Expr.Scope.new(record, %{},
               ash_resource_module: resource,
               actor: Keyword.get(opts, :actor),
               tenant: Keyword.get(opts, :tenant),
               context: Keyword.get(opts, :context, %{})
             )
           ) do
      location
    else
      _own_template -> nil
    end
  end

  defp projected(path, query_names, resource, record) do
    query =
      for name <- query_names,
          value = Map.get(record, name),
          not is_nil(value) and value != "",
          to_string(value) != declared_default(resource, name),
          do: {name, to_string(value)}

    if query == [], do: path, else: path <> "?" <> URI.encode_query(query)
  end

  defp preserve_query_params(location, params)
       when is_binary(location) and is_map(params) and map_size(params) > 0 do
    uri = URI.parse(location)

    query =
      case uri.query do
        query when is_binary(query) -> URI.decode_query(query)
        _none -> %{}
      end

    preserved =
      params
      |> Enum.flat_map(fn
        {key, value} when not is_nil(value) and value != "" ->
          [{to_string(key), to_string(value)}]

        _empty ->
          []
      end)
      |> Map.new()

    query = Map.merge(preserved, query)
    encoded = query |> Enum.sort() |> URI.encode_query()
    URI.to_string(%{uri | query: if(encoded == "", do: nil, else: encoded)})
  end

  defp preserve_query_params(location, _params), do: location

  defp declared_default(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      %{default: default} when not is_nil(default) and not is_function(default) ->
        to_string(default)

      _none ->
        nil
    end
  end
end
