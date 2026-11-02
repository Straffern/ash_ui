defmodule AshUi.Phoenix.EnsureSessionId do
  @moduledoc """
  Stores a stable AshUi session id in the Plug session, so HTTP
  remounts (refresh, direct entry, test drivers that remount per
  navigation) continue the same UI session. Add to the host's browser
  pipeline:

      plug AshUi.Phoenix.EnsureSessionId
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Plug.Conn.get_session(conn, "ash_ui_session_id") do
      id when is_binary(id) and id != "" ->
        conn

      _missing ->
        Plug.Conn.put_session(
          conn,
          "ash_ui_session_id",
          AshUi.Session.generated_session_id()
        )
    end
  end
end
