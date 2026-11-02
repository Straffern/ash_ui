defmodule AshUi.Phoenix.BridgeLive do
  @moduledoc false

  use Phoenix.LiveView

  alias AshUi.Phoenix.LiveSession
  alias AshUi.Phoenix.RouteMetadata
  alias AshUi.Phoenix, as: BlueprintPhoenix

  def generate_session(conn, opts), do: LiveSession.generate_session(conn, opts)

  def on_mount(name, params, session, socket),
    do: LiveSession.on_mount(name, params, session, socket)

  @impl true
  def mount(params, session, socket) do
    metadata = route_metadata(socket, session, params)
    socket = put_route_metadata(socket, metadata)

    BlueprintPhoenix.mount(
      metadata.resource,
      params,
      session,
      socket,
      bridge_opts(socket, session, params)
    )
  end

  @impl true
  def render(assigns), do: BlueprintPhoenix.render_shell(assigns)

  @impl true
  def terminate(reason, socket), do: BlueprintPhoenix.runtime_terminate(reason, socket)

  defp route_metadata(socket, session, params) do
    case route_metadata_from_live_action(socket.assigns[:live_action], params) do
      %RouteMetadata{} = metadata ->
        metadata

      nil ->
        route_metadata_from_socket_or_session(socket, session)
    end
  end

  defp route_metadata_from_socket_or_session(socket, session) do
    metadata =
      socket.private
      |> Map.get(:phoenix_live_view, %{})
      |> Map.get(:metadata, %{})
      |> route_metadata_from_live_metadata()

    case metadata || RouteMetadata.from_session(session) do
      %RouteMetadata{} = metadata -> metadata
      _other -> raise ArgumentError, "missing AshUi route metadata"
    end
  end

  # LiveView redirects authorize the destination route but reuse the signed
  # source session. `live_action` is Phoenix's destination-route contract;
  # session metadata is therefore only a fallback for non-router mounts.
  defp route_metadata_from_live_action(resource, params) when is_atom(resource) do
    resource
    |> AshUi.Location.routes()
    |> Enum.map(fn {path, query} ->
      route_params =
        for segment <- String.split(path, "/", trim: true),
            <<prefix::binary-size(1), name::binary>> <- [segment],
            prefix in [":", "*"],
            do: name

      {path, query, route_params}
    end)
    |> Enum.filter(fn {_path, _query, route_params} ->
      Enum.all?(route_params, &Map.has_key?(params, &1))
    end)
    |> Enum.max_by(fn {_path, _query, route_params} -> length(route_params) end, fn -> nil end)
    |> case do
      {path, query, route_params} ->
        %RouteMetadata{
          resource: resource,
          path: path,
          query: query,
          route_params: Map.take(params, route_params),
          query_params: Map.take(params, Enum.map(query, &to_string/1))
        }

      nil ->
        nil
    end
  end

  defp route_metadata_from_live_action(_resource, _params), do: nil

  defp put_route_metadata(socket, metadata) do
    live_metadata =
      socket.private
      |> Map.get(:phoenix_live_view, %{})
      |> Map.get(:metadata, %{})
      |> Map.put(:ash_ui_route_metadata, metadata)

    phoenix_live_view =
      socket.private
      |> Map.get(:phoenix_live_view, %{})
      |> Map.put(:metadata, live_metadata)

    Phoenix.LiveView.put_private(socket, :phoenix_live_view, phoenix_live_view)
  end

  defp route_metadata_from_live_metadata(%{
         ash_ui_route_metadata: %RouteMetadata{} = metadata
       }),
       do: metadata

  defp route_metadata_from_live_metadata(%RouteMetadata{} = metadata), do: metadata
  defp route_metadata_from_live_metadata(_metadata), do: nil

  defp bridge_opts(socket, session, params) do
    context =
      %{
        connected?: Phoenix.LiveView.connected?(socket),
        current_user: socket.assigns[:current_user],
        endpoint: socket.endpoint,
        otp_app: socket.endpoint.config(:otp_app),
        params: params,
        route_metadata: route_metadata(socket, session, params),
        session: session
      }
      |> Map.merge(Map.get(socket.assigns, :ash_ui_context, %{}))

    [
      context: context,
      otp_app: context.otp_app,
      pubsub_server: endpoint_pubsub(socket),
      after_event: socket.assigns[:ash_ui_after_event]
    ]
  end

  defp endpoint_pubsub(socket) do
    socket.endpoint.config(:pubsub_server)
  rescue
    _error in [ArgumentError, FunctionClauseError, KeyError, UndefinedFunctionError] -> nil
  end
end
