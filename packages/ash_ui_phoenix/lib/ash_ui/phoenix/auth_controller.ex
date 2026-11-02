defmodule AshUi.Phoenix.AuthController do
  # Default auth callbacks: session + redirect ONLY. User-visible messages
  # are not part of the bridge contract — hosts that want auth messages
  # implement their own controller and write their own session-scoped
  # notice rows.
  @moduledoc false

  use Phoenix.Controller, formats: [:html, :json]
  use AshAuthentication.Phoenix.Controller

  def success(conn, activity, user, _token) do
    context = auth_context(conn, activity: activity, user: user)
    resource = auth_resource(conn)

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    |> assign(:current_user, user)
    |> redirect(to: export_or_default(resource, :success_to, context, context.return_to))
  end

  def failure(conn, activity, reason) do
    context = auth_context(conn, activity: activity, reason: reason)
    resource = auth_resource(conn)

    conn
    |> redirect(to: export_or_default(resource, :failure_to, context, "/sign-in"))
  end

  def sign_out(conn, _params) do
    context = auth_context(conn)
    resource = auth_resource(conn)

    conn
    |> clear_session(otp_app(conn))
    |> redirect(to: export_or_default(resource, :sign_out_to, context, context.return_to))
  end

  defp auth_resource(conn) do
    conn
    |> otp_app()
    |> AshUi.Phoenix.configured_resource(:auth_callback_resource)
  end

  # exports died with the second model; the auth callback resource can no
  # longer override redirect values, so callers get the defaults
  defp export_or_default(_resource, _export_name, _context, default), do: default

  defp auth_context(conn, extra \\ []) do
    conn
    |> base_context()
    |> Map.merge(Map.new(extra))
  end

  defp base_context(conn) do
    %{
      return_to: get_session(conn, :return_to) || "/",
      conn: conn,
      session: get_session(conn)
    }
  end

  defp otp_app(conn) do
    conn.private.phoenix_endpoint.config(:otp_app)
  end
end
