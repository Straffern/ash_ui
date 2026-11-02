defmodule AshUi.Phoenix.RootLayoutTest do
  # DESIGN §9: document assembly is a framework function of declared data.
  # The layout links the routed resource's EFFECTIVE stylesheets (declared
  # order), emits the framework runtime scripts unconditionally, derives
  # <base href> from the mount scope, and stamps runtime state. The
  # root_layout_* env/assign channels are deleted.
  use ExUnit.Case, async: false

  alias AshUi.Phoenix.RootLayout
  alias AshUi.Phoenix.RouteMetadata

  defmodule StyledPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    ash_ui do
      stylesheets(["test/support/assets/routed_fixtures.css"])
    end

    routes do
      route("/styled")
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(box(:root, [], [text("styled")])))
    end
  end

  setup do
    old_otp_app = Application.get_env(:ash_ui_phoenix, :otp_app)
    Application.put_env(:ash_ui_phoenix, :otp_app, :ash_ui_phoenix)

    on_exit(fn ->
      case old_otp_app do
        nil -> Application.delete_env(:ash_ui_phoenix, :otp_app)
        value -> Application.put_env(:ash_ui_phoenix, :otp_app, value)
      end
    end)
  end

  test "links the routed resource's effective stylesheets in declared order with a base href" do
    html = render(%{inner_content: "Body", conn: routed_conn(StyledPage)})

    assert html =~ ~s(<base href="/">)

    assert html =~
             ~s(<link phx-track-static rel="stylesheet" href="test/support/assets/routed_fixtures.css">)

    [head, _body] = String.split(html, "</head>", parts: 2)
    assert head =~ "routed_fixtures.css"
  end

  test "derives the base href from the mount scope at any route depth" do
    conn = %{routed_conn(StyledPage) | script_name: ["admin", "app"]}
    html = render(%{inner_content: "Body", conn: conn})

    assert html =~ ~s(<base href="/admin/app/">)
  end

  test "emits the framework runtime scripts unconditionally" do
    for assigns <- [
          %{inner_content: "Body"},
          %{inner_content: "Body", conn: routed_conn(StyledPage)}
        ] do
      html = render(assigns)

      assert html =~ ~s(type="text/javascript" src="/assets/phoenix.min.js")
      assert html =~ ~s(type="text/javascript" src="/assets/phoenix_live_view.min.js")
      assert html =~ ~s(type="text/javascript" src="/assets/ash_ui.min.js")

      assert [_before_phoenix, after_phoenix] =
               String.split(html, ~s(src="/assets/phoenix.min.js"), parts: 2)

      assert [_before_live_view, after_live_view] =
               String.split(after_phoenix, ~s(src="/assets/phoenix_live_view.min.js"), parts: 2)

      assert after_live_view =~ ~s(src="/assets/ash_ui.min.js")
    end
  end

  test "a document without route metadata links no stylesheets — no fallbacks" do
    html = render(%{inner_content: "Body"})

    refute html =~ "<link"
    refute html =~ "stylesheet"
  end

  test "runtime state stamps data-theme, font custom properties, and scaled root font on <html>" do
    html =
      render(%{
        inner_content: "Body",
        ash_ui_runtime_state: %{
          scheme: "dark",
          fonts: %{mono: "Iosevka", ui: "Inter"},
          zoom: 1.25
        }
      })

    assert html =~ ~s(<html data-theme="dark")
    assert html =~ "--font-mono: Iosevka"
    assert html =~ "--font-ui: Inter"
    assert html =~ "font-size: 20px"
  end

  test "absent runtime state stamps nothing" do
    html = render(%{inner_content: "Body"})

    assert html =~ "<html><head>"
    refute html =~ "data-theme"
    refute html =~ "zoom:"
    refute html =~ "--font-"
  end

  test "title assembly keeps page title, suffix, and default title" do
    Application.put_env(:ash_ui_phoenix, :root_layout_default_title, "Hello!")
    Application.put_env(:ash_ui_phoenix, :root_layout_title_suffix, " · Example")

    on_exit(fn ->
      Application.delete_env(:ash_ui_phoenix, :root_layout_default_title)
      Application.delete_env(:ash_ui_phoenix, :root_layout_title_suffix)
    end)

    assert render(%{inner_content: "Body", page_title: "Inbox"}) =~
             ~s(<title>Inbox · Example</title>)

    assert render(%{inner_content: "Body"}) =~ ~s(<title>Hello! · Example</title>)
  end

  test "the deleted root_layout_* channels are inert" do
    html =
      render(%{
        inner_content: "Body",
        root_layout_stylesheets: ["/scoped.css"],
        root_layout_scripts: [{"/scoped.js", "module"}],
        root_layout_theme_assets: [%{}],
        root_layout_ui_zoom: 3.0
      })

    refute html =~ "/scoped.css"
    refute html =~ "/scoped.js"
    refute html =~ "zoom"
  end

  defp routed_conn(resource) do
    %Plug.Conn{
      private: %{
        ash_ui_route_metadata: RouteMetadata.new(resource, "/styled", [])
      },
      script_name: []
    }
  end

  defp render(assigns) do
    {:safe, iodata} = RootLayout.render(assigns)
    IO.iodata_to_binary(iodata)
  end
end
