defmodule AshUi.Datastar.ArmErrorDistributionTest do
  @moduledoc """
  Error distribution INSIDE branch arms through the real datastar POST
  cycle: a failed dispatch paints error state authored inside an `if` arm
  (arm slots are first-class table slots), and the next successful
  dispatch clears it.
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias AshUi.Datastar.{Bridge, Store}

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(false)
    end

    ash_ui do
      stylesheets(["test/support/assets/datastar_test.css"])
    end

    routes do
      route("/arm-errors")
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:editing?, :boolean, allow_nil?: false, default: true, public?: true)

      attribute(:title, :string,
        allow_nil?: false,
        default: "untitled",
        public?: true,
        constraints: [allow_empty?: true, trim?: false]
      )
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
      end

      update :save do
        require_atomic?(false)
        argument(:title, :string, allow_nil?: true)

        validate(fn changeset, _context ->
          case Ash.Changeset.get_argument(changeset, :title) do
            title when is_binary(title) and byte_size(title) >= 3 -> :ok
            _too_short -> {:error, field: :title, message: "title too short"}
          end
        end)

        change(set_attribute(:title, arg(:title)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [], [
            if editing? do
              box(:editor, [], [
                if field_errors(:title) != [] do
                  paragraph(:title_error, [], [text("title too short")])
                end,
                button(:save_bad, [type: :button, on_click: :save, action_input: %{title: "x"}], [
                  text("save bad")
                ]),
                button(
                  :save_ok,
                  [type: :button, on_click: :save, action_input: %{title: "a valid title"}],
                  [text("save ok")]
                )
              ])
            else
              paragraph(:closed, [], [text("closed")])
            end
          ])
        )
      )
    end
  end

  setup do
    Ash.DataLayer.Ets.stop(Page)
    AshUi.Notification.MatchIndex.reset()
    :ok
  end

  defp opts, do: Bridge.init(resources: [Page])

  defp cookie(conn),
    do: conn |> get_resp_header("set-cookie") |> List.first() |> String.split(";") |> hd()

  defp cookie_value(cookie), do: cookie |> String.split("=", parts: 2) |> List.last()

  defp binding_key(html, label) do
    [element] = Regex.run(~r/<button[^>]*>#{Regex.escape(label)}<\/button>/, html)

    [_, encoded_key] =
      Regex.run(
        ~r/data-on:click="[^"]*?\/_ash_ui\/dispatch\/([^&'"),\s]+)/,
        element
      )

    URI.decode(encoded_key)
  end

  defp dispatch!(key, cookie) do
    conn =
      conn(
        :post,
        "/_ash_ui/dispatch/" <> URI.encode(key),
        Jason.encode!(%{"datastar" => %{}})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", cookie)
      |> Bridge.call(opts())

    assert conn.status == 200, conn.resp_body
    conn
  end

  test "arm error slots exist in the compiled datastar table" do
    table = Bridge.cached_table(Page, :view, %{all: [], patch: []})

    assert Enum.any?(table.error_slots, &(is_binary(&1) and &1 =~ "/t")),
           "expected error slots under the then-arm, got: #{inspect(table.error_slots)}"
  end

  test "a failing dispatch paints the arm error surface and success clears it" do
    mount = conn(:get, "/arm-errors") |> Bridge.call(opts())
    session_id = mount |> cookie() |> cookie_value()
    refute mount.resp_body =~ "title too short"

    bad = dispatch!(binding_key(mount.resp_body, "save bad"), cookie(mount))
    assert bad.resp_body =~ "title too short"
    assert Store.get(session_id).errors != []
    assert Store.get(session_id).record.title == "untitled"

    ok = dispatch!(binding_key(mount.resp_body, "save ok"), cookie(mount))
    assert Store.get(session_id).errors == []
    assert Store.get(session_id).record.title == "a valid title"
    refute ok.resp_body =~ "title too short"
  end
end
