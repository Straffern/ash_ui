defmodule AshUi.Datastar.CalcDepNarrowingTest do
  @moduledoc """
  Bridge-loop coverage for declaration-derived CALCULATION dependencies (the
  canonical reload contract in `AshUi.Reload`), through the real
  datastar POST cycle: a derived root calculation over a relationship — the
  flattened-rows / date-sections shape — keeps the zero-reload keystroke
  contract, and refreshes when its source data changes (dispatch echo).
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias AshUi.Datastar.{Bridge, Store}

  @counter_table :ds_calc_narrowing_read_counts

  defmodule Row do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false,
      notifiers: [AshUi.Notifier]

    ets do
      private?(false)
    end

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:page_key, :string, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read])

      read :bench_relationship do
        prepare(fn query, _context ->
          :ets.update_counter(:ds_calc_narrowing_read_counts, :rows, 1, {:rows, 0})
          query
        end)
      end

      create :create do
        primary?(true)
        accept([:id, :page_key, :body])
      end
    end
  end

  defmodule Digest do
    # The derived-root module calculation: `load/3` IS its dependency
    # declaration (the date-sections analog — derived entirely from :rows).
    use Ash.Resource.Calculation

    @impl true
    def load(_query, _opts, _context), do: [rows: [:body]]

    @impl true
    def calculate(records, _opts, _context) do
      Enum.map(records, fn record ->
        record.rows |> List.wrap() |> Enum.map(& &1.body) |> Enum.sort() |> Enum.join("|")
      end)
    end
  end

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
      route("/calcdep")
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:page_key, :string, allow_nil?: false, default: "shared", public?: true)

      attribute(:draft, :string,
        allow_nil?: false,
        default: "",
        public?: true,
        constraints: [allow_empty?: true, trim?: false]
      )
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :rows, AshUi.Datastar.CalcDepNarrowingTest.Row do
        source_attribute(:page_key)
        destination_attribute(:page_key)
        read_action(:bench_relationship)
      end
    end

    actions do
      defaults([:read])

      create :mount do
      end

      update :type do
        require_atomic?(false)
        argument(:value, :string, allow_nil?: false)
        change(set_attribute(:draft, arg(:value)))
      end

      update :send do
        require_atomic?(false)

        change(fn changeset, context ->
          Ash.Changeset.after_action(changeset, fn _changeset, record ->
            _row =
              AshUi.Datastar.CalcDepNarrowingTest.Row
              |> Ash.Changeset.for_create(
                :create,
                %{id: Ash.UUID.generate(), page_key: record.page_key, body: "sent"},
                Keyword.merge(
                  [domain: AshUi.AshDomainFallback],
                  Ash.Scope.to_opts(context)
                )
              )
              |> Ash.create!()

            {:ok, record}
          end)
        end)

        change(set_attribute(:draft, ""))
      end
    end

    calculations do
      calculate(:digest, :string, AshUi.Datastar.CalcDepNarrowingTest.Digest)

      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [], [
            inline(:digest, [], [text(digest)]),
            list(:transcript, [], [
              each(rows, :row, [key: row.id], [item(:row, [], [text(row.body)])])
            ]),
            button(:type, [type: :button, on_click: :type, action_input: %{value: "d"}], [
              text(draft)
            ]),
            button(:send, [type: :button, on_click: :send], [text("send")])
          ])
        )
      )
    end
  end

  setup do
    if :ets.whereis(@counter_table) == :undefined do
      :ets.new(@counter_table, [:named_table, :public, :set])
    end

    :ets.delete_all_objects(@counter_table)
    Ash.DataLayer.Ets.stop(Page)
    Ash.DataLayer.Ets.stop(Row)
    AshUi.Notification.MatchIndex.reset()
    :ok
  end

  defp row_reads do
    case :ets.lookup(@counter_table, :rows) do
      [{:rows, n}] -> n
      [] -> 0
    end
  end

  defp opts, do: Bridge.init(resources: [Page])

  defp cookie(conn),
    do: conn |> get_resp_header("set-cookie") |> List.first() |> String.split(";") |> hd()

  defp cookie_value(cookie), do: cookie |> String.split("=", parts: 2) |> List.last()

  defp binding_key(html, element_regex, event) do
    [element] = Regex.run(element_regex, html)

    [_, encoded_key] =
      Regex.run(
        ~r/data-on:#{Regex.escape(event)}="[^"]*?\/_ash_ui\/dispatch\/([^&'"),\s]+)/,
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

  defp seed_rows do
    for body <- ["a", "b"] do
      Row
      |> Ash.Changeset.for_create(
        :create,
        %{id: body, page_key: "shared", body: body},
        domain: AshUi.AshDomainFallback
      )
      |> Ash.create!()
    end
  end

  test "a keystroke leaves the derived calc and its source relationship untouched" do
    seed_rows()

    mount = conn(:get, "/calcdep") |> Bridge.call(opts())
    session_id = mount |> cookie() |> cookie_value()
    record = Store.get(session_id).record
    assert record.digest == "a|b"

    type_key = binding_key(mount.resp_body, ~r/<button[^>]*>[^<]*<\/button>/, "click")

    reads_before = row_reads()
    dispatch!(type_key, cookie(mount))

    refreshed = Store.get(session_id).record
    assert refreshed.draft == "d"
    assert row_reads() == reads_before
    assert refreshed.rows == record.rows
    assert refreshed.digest == "a|b"
  end

  test "a dispatch whose write echoes on :rows refreshes the derived calc" do
    seed_rows()

    mount = conn(:get, "/calcdep") |> Bridge.call(opts())
    session_id = mount |> cookie() |> cookie_value()
    assert Store.get(session_id).record.digest == "a|b"

    send_key = binding_key(mount.resp_body, ~r/<button[^>]*>send<\/button>/, "click")
    dispatch!(send_key, cookie(mount))

    refreshed = Store.get(session_id).record
    assert Enum.map(refreshed.rows, & &1.body) |> Enum.sort() == ["a", "b", "sent"]
    assert refreshed.digest |> String.split("|") |> Enum.sort() == ["a", "b", "sent"]
  end
end
