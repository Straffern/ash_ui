defmodule AshUi.Phoenix.BearerCsrfSkip do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token when token != "" ->
        put_private(conn, :plug_skip_csrf_protection, true)

      _other ->
        conn
    end
  end
end
