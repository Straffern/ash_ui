defmodule AshUi.Phoenix.RouteMetadata do
  @moduledoc """
  Resource route metadata carried from Phoenix route expansion into the LiveView host.
  """

  @enforce_keys [:resource, :path]
  defstruct [:resource, :path, query: [], route_params: %{}, query_params: %{}]

  @type t :: %__MODULE__{
          resource: module(),
          path: String.t(),
          query: [atom()],
          route_params: map(),
          query_params: map()
        }

  def new(resource, path, query)
      when is_atom(resource) and is_binary(path) and is_list(query) do
    %__MODULE__{resource: resource, path: path, query: query}
  end

  def from_private(%{ash_ui_route_metadata: %__MODULE__{} = metadata}), do: metadata
  def from_private(_private), do: nil

  def from_session(%{"ash_ui_metadata" => %__MODULE__{} = metadata}), do: metadata
  def from_session(_session), do: nil

  def put_request(%__MODULE__{} = metadata, %Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    put_request(metadata, conn.query_params, conn.path_params, conn.params, conn.request_path)
  end

  def put_request(%__MODULE__{} = metadata, query_params, path_params, conn_params, request_path) do
    route_params =
      case normalize_params(path_params) do
        params when map_size(params) > 0 -> params
        _ -> infer_route_params(metadata.path, conn_params, request_path)
      end

    %{metadata | query_params: normalize_params(query_params), route_params: route_params}
  end

  defp normalize_params(params) when is_map(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp normalize_params(_), do: %{}

  defp infer_route_params(path, conn_params, request_path) do
    values =
      if is_binary(request_path) do
        path
        |> String.split("/", trim: true)
        |> Enum.zip(String.split(request_path, "/", trim: true))
        |> Map.new(fn
          {":" <> key, value} -> {key, value}
          {_static, _value} -> {nil, nil}
        end)
        |> Map.delete(nil)
      else
        %{}
      end

    if map_size(values) > 0 do
      values
    else
      keys = for ":" <> key <- String.split(path, "/", trim: true), do: key
      Map.take(normalize_params(conn_params), keys)
    end
  end
end
