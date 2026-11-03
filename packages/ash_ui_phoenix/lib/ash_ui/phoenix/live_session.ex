defmodule AshUi.Phoenix.LiveSession do
  @moduledoc false

  alias AshUi.Phoenix.RouteMetadata
  import Phoenix.Component, only: [assign: 3]

  # AshAuthentication is an optional dependency. Without it, the session
  # carries the host's hooks plus the Ash tenant and context, and the host's
  # own on_mount hooks assign the actor.
  if Code.ensure_loaded?(AshAuthentication.Phoenix.LiveSession) do
    defdelegate assign_new_resources(socket, session), to: AshAuthentication.Phoenix.LiveSession

    defdelegate assign_new_resources(socket, session, opts),
      to: AshAuthentication.Phoenix.LiveSession

    defp base_session(conn, otp_app, hooks),
      do: AshAuthentication.Phoenix.LiveSession.generate_session(conn, otp_app, hooks)

    defp base_on_mount(name, params, session, socket),
      do: AshAuthentication.Phoenix.LiveSession.on_mount(name, params, session, socket)

    defp assign_authenticated(socket, session),
      do: AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)
  else
    defp base_session(conn, _otp_app, hooks) do
      hooks
      |> Enum.reduce(%{}, fn {m, f, a}, acc -> Map.merge(acc, apply(m, f, [conn | a]) || %{}) end)
      |> Map.put("tenant", Ash.PlugHelpers.get_tenant(conn))
      |> Map.put("context", Ash.PlugHelpers.get_context(conn))
    end

    defp base_on_mount(:default, _params, session, socket) do
      case socket.assigns[:current_tenant] || session["tenant"] do
        nil -> {:cont, socket}
        tenant -> {:cont, Phoenix.Component.assign_new(socket, :current_tenant, fn -> tenant end)}
      end
    end

    defp base_on_mount(_name, _params, _session, socket), do: {:cont, socket}

    defp assign_authenticated(socket, _session), do: socket
  end

  def on_mount(:current_user, params, session, socket) do
    socket
    |> maybe_assign_otp_app(session)
    |> then(&on_mount(:default, params, session, &1))
  end

  def on_mount(:live_user_optional, _params, session, socket) do
    socket = maybe_assign_current_user(socket, session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, session, socket) do
    socket = maybe_assign_current_user(socket, session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, session, socket) do
    socket = maybe_assign_current_user(socket, session)

    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(name, params, session, socket) do
    socket = maybe_assign_otp_app(socket, session)
    {status, socket} = base_on_mount(name, params, session, socket)
    {status, maybe_put_route_metadata(socket, session)}
  end

  def generate_session(conn, opts \\ [])

  def generate_session(conn, opts) when is_list(opts) do
    otp_app = Keyword.get(opts, :otp_app)
    additional_hooks = Keyword.get(opts, :session, [])

    conn
    |> base_session(otp_app, List.wrap(additional_hooks))
    |> maybe_put_auth_otp_app(otp_app)
    |> maybe_merge_route_metadata(conn)
    |> maybe_put_session_id(conn)
  end

  def generate_session(conn, {key, value}) when is_atom(key) do
    generate_session(conn, [{key, value}])
  end

  def generate_session(conn, otp_app) when is_atom(otp_app) or is_nil(otp_app) do
    conn
    |> base_session(otp_app, [])
    |> maybe_put_auth_otp_app(otp_app)
    |> maybe_merge_route_metadata(conn)
    |> maybe_put_session_id(conn)
  end

  def generate_session(conn, otp_app, additional_hooks) do
    conn
    |> base_session(otp_app, additional_hooks)
    |> maybe_put_auth_otp_app(otp_app)
    |> maybe_merge_route_metadata(conn)
    |> maybe_put_session_id(conn)
  end

  defp maybe_assign_current_user(socket, session) do
    socket = maybe_assign_otp_app(socket, session)

    case Map.get(socket.assigns, :current_user) do
      nil -> assign_authenticated(socket, session)
      _current_user -> socket
    end
  end

  defp maybe_assign_otp_app(socket, %{"otp_app" => otp_app}) when is_atom(otp_app) do
    assign(socket, :otp_app, otp_app)
  end

  defp maybe_assign_otp_app(socket, _session), do: socket

  defp maybe_put_auth_otp_app(session, otp_app) when is_atom(otp_app) and is_map(session) do
    Map.put(session, "otp_app", otp_app)
  end

  defp maybe_put_auth_otp_app(session, _otp_app), do: session

  # Session identity is browser-session-stable: prefer the id the
  # EnsureSessionId plug stored in the Plug session, so HTTP remounts
  # (refresh, direct entry) continue the same UI session.
  defp maybe_put_session_id(session, conn) when is_map(session) do
    Map.put_new_lazy(session, "ash_ui_session_id", fn ->
      plug_session_id(conn) || AshUi.Session.generated_session_id()
    end)
  end

  defp plug_session_id(conn) do
    case Plug.Conn.get_session(conn, "ash_ui_session_id") do
      id when is_binary(id) and id != "" -> id
      _missing -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp maybe_put_route_metadata(socket, session) do
    case route_metadata(session, socket.private[:connect_info]) do
      nil ->
        socket

      metadata ->
        live_metadata =
          socket.private
          |> Map.get(:phoenix_live_view, %{})
          |> Map.get(:metadata, %{})
          |> normalize_live_metadata()
          |> Map.put(:ash_ui_route_metadata, metadata)

        phoenix_live_view =
          socket.private
          |> Map.get(:phoenix_live_view, %{})
          |> Map.put(:metadata, live_metadata)

        Phoenix.LiveView.put_private(socket, :phoenix_live_view, phoenix_live_view)
    end
  end

  defp maybe_merge_route_metadata(session, conn) do
    case route_metadata(%{}, conn) do
      nil -> session
      metadata -> Map.put(session, "ash_ui_metadata", metadata)
    end
  end

  defp route_metadata(session, connect_info) when is_map(session) do
    RouteMetadata.from_session(session) || route_metadata_from_connect_info(connect_info)
  end

  defp route_metadata(_session, connect_info), do: route_metadata_from_connect_info(connect_info)

  defp route_metadata_from_connect_info(%Plug.Conn{private: private} = conn)
       when is_map(private) do
    with %RouteMetadata{} = metadata <- RouteMetadata.from_private(private) do
      RouteMetadata.put_request(metadata, conn)
    end
  end

  defp route_metadata_from_connect_info(%{private: private}) when is_map(private) do
    RouteMetadata.from_private(private)
  end

  defp route_metadata_from_connect_info(_connect_info), do: nil

  defp normalize_live_metadata(%{__struct__: _struct}), do: %{}
  defp normalize_live_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_live_metadata(_metadata), do: %{}
end
