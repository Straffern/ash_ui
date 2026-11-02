defmodule AshUi.Phoenix.RuntimeStaticTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test

  defmodule Router do
    import Plug.Conn

    def init(opts), do: opts
    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  defmodule Endpoint do
    use AshUi.Phoenix.Endpoint,
      otp_app: :ash_ui_phoenix,
      router: Router,
      session_options: [store: :cookie, key: "_ash_ui_static_test", signing_salt: "static"],
      static_paths: []
  end

  setup_all do
    start_supervised!(Endpoint)
    :ok
  end

  test "generated endpoint serves the AshUi platform bundle" do
    conn =
      :get
      |> conn("/assets/ash_ui.min.js")
      |> Endpoint.call([])

    assert conn.status == 200
    assert ["text/javascript" <> _] = get_resp_header(conn, "content-type")
    assert conn.resp_body =~ "AshUi"
  end
end
