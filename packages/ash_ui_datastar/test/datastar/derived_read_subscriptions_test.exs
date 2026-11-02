defmodule AshUi.Datastar.DerivedReadSubscriptionsTest do
  @moduledoc """
  "Whatever a page reads, it subscribes to" through the Datastar bridge: the
  updates stream registers subscriptions for the rows a rendered DERIVED
  value is computed from — a module calculation's `load/3` relationship, an
  aggregate over a relationship, an aggregate over an unrelated resource, and
  a calculation built on another calculation — although Ash loads those
  dependencies as hidden internal loads. A foreign write to a dependency row
  reaches the stream and repaints the value; a resource the page never reads
  is not subscribed.
  """

  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias AshUi.Datastar.{Bridge, Store}
  alias AshUi.Notification.MatchIndex

  defmodule DigestRow do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false,
      notifiers: [AshUi.Notifier]

    ets do
      private?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:page_key, :string, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, default: "-", public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:page_key, :body])
      end
    end
  end

  defmodule CountedRow do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false,
      notifiers: [AshUi.Notifier]

    ets do
      private?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:page_key, :string, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, default: "-", public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:page_key, :body])
      end
    end
  end

  defmodule NestedRow do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false,
      notifiers: [AshUi.Notifier]

    ets do
      private?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:page_key, :string, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, default: "-", public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:page_key, :body])
      end
    end
  end

  # Reached only through an UNRELATED aggregate. Ash authorizes that
  # aggregate's query against its resource's domain, so it lives in one.
  defmodule LooseRow do
    @moduledoc false
    use Ash.Resource,
      domain: AshUi.Datastar.DerivedReadSubscriptionsTest.LooseDomain,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false,
      notifiers: [AshUi.Notifier]

    ets do
      private?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:page_key, :string, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, default: "-", public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:page_key, :body])
      end
    end
  end

  # Never read by the page in any way.
  defmodule StrangerRow do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false,
      notifiers: [AshUi.Notifier]

    ets do
      private?(false)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:page_key, :string, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, default: "-", public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:page_key, :body])
      end
    end
  end

  defmodule LooseDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshUi.Datastar.DerivedReadSubscriptionsTest.LooseRow)
    end
  end

  defmodule Digest do
    @moduledoc false
    use Ash.Resource.Calculation

    @impl true
    def load(_query, opts, _context), do: [{Keyword.fetch!(opts, :rel), [:body]}]

    @impl true
    def calculate(records, opts, _context) do
      rel = Keyword.fetch!(opts, :rel)

      Enum.map(records, fn record ->
        record
        |> Map.get(rel)
        |> List.wrap()
        |> Enum.map(& &1.body)
        |> Enum.sort()
        |> Enum.join("|")
      end)
    end
  end

  defmodule Page do
    @moduledoc false
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
      route("/derived-reads")
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:page_key, :string, allow_nil?: false, default: "shared", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :digest_rows, AshUi.Datastar.DerivedReadSubscriptionsTest.DigestRow do
        source_attribute(:page_key)
        destination_attribute(:page_key)
      end

      has_many :counted_rows, AshUi.Datastar.DerivedReadSubscriptionsTest.CountedRow do
        source_attribute(:page_key)
        destination_attribute(:page_key)
      end

      has_many :nested_rows, AshUi.Datastar.DerivedReadSubscriptionsTest.NestedRow do
        source_attribute(:page_key)
        destination_attribute(:page_key)
      end
    end

    actions do
      defaults([:read])

      create :mount do
      end
    end

    aggregates do
      count(:counted, :counted_rows)

      count :loose_count, AshUi.Datastar.DerivedReadSubscriptionsTest.LooseRow do
        filter(expr(page_key == parent(page_key)))
      end
    end

    calculations do
      calculate(
        :digest,
        :string,
        {AshUi.Datastar.DerivedReadSubscriptionsTest.Digest, rel: :digest_rows}
      )

      calculate(
        :inner_digest,
        :string,
        {AshUi.Datastar.DerivedReadSubscriptionsTest.Digest, rel: :nested_rows}
      )

      calculate(:outer_digest, :string, expr("<" <> inner_digest <> ">"))

      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [], [
            inline(:digest, [], [text(digest)]),
            inline(:counted, [], [text(counted)]),
            inline(:loose, [], [text(loose_count)]),
            inline(:outer, [], [text(outer_digest)])
          ])
        )
      )
    end
  end

  @rows [
    __MODULE__.DigestRow,
    __MODULE__.CountedRow,
    __MODULE__.NestedRow,
    __MODULE__.LooseRow,
    __MODULE__.StrangerRow
  ]

  setup do
    Enum.each([Page | @rows], &Ash.DataLayer.Ets.stop/1)
    MatchIndex.reset()
    :ok
  end

  defp config,
    do: Bridge.init(resources: [Page], updates_max_events: 1, updates_heartbeat: 5_000)

  defp create!(resource, attrs) do
    resource
    |> Ash.Changeset.for_create(:create, attrs,
      domain: Ash.Resource.Info.domain(resource) || AshUi.AshDomainFallback
    )
    |> Ash.create!()
  end

  defp cookie(conn),
    do: conn |> get_resp_header("set-cookie") |> hd() |> String.split(";", parts: 2) |> hd()

  defp cookie_value(cookie), do: cookie |> String.split("=", parts: 2) |> List.last()

  # Mount, attach the updates stream, and wait for its subscription set.
  defp mount_and_stream do
    create!(__MODULE__.DigestRow, %{page_key: "shared", body: "a"})
    create!(__MODULE__.CountedRow, %{page_key: "shared"})
    create!(__MODULE__.NestedRow, %{page_key: "shared", body: "n"})
    create!(__MODULE__.LooseRow, %{page_key: "shared"})

    mount = conn(:get, "/derived-reads") |> Bridge.call(config())
    assert mount.status == 200, mount.resp_body
    cookie = cookie(mount)
    session_id = cookie_value(cookie)

    record = Store.get(session_id).record
    assert record.digest == "a"
    assert record.counted == 1
    assert record.loose_count == 1
    assert record.outer_digest == "<n>"
    assert %Ash.NotLoaded{} = record.digest_rows
    assert %Ash.NotLoaded{} = record.counted_rows
    assert %Ash.NotLoaded{} = record.nested_rows

    updates =
      Task.async(fn ->
        conn(:get, "/_ash_ui/updates")
        |> put_req_header("cookie", cookie)
        |> Bridge.call(config())
      end)

    registered? =
      Enum.reduce_while(1..100, false, fn _, _ ->
        if Store.client_count(session_id) == 1 do
          {:halt, true}
        else
          receive do
          after
            10 -> {:cont, false}
          end
        end
      end)

    assert registered?
    {session_id, updates}
  end

  defp await_record(session_id, updates) do
    assert Task.await(updates, 5_000).status == 200
    Store.get(session_id).record
  end

  test "a module calculation's load/3 relationship is subscribed key-matched" do
    {session_id, updates} = mount_and_stream()

    assert [{_ref, subscription}] = MatchIndex.subs_for(__MODULE__.DigestRow)
    assert subscription.attrs == [page_key: "shared"]

    create!(__MODULE__.DigestRow, %{page_key: "shared", body: "b"})
    assert await_record(session_id, updates).digest == "a|b"
  end

  test "an aggregate over a relationship is subscribed key-matched" do
    {session_id, updates} = mount_and_stream()

    assert [{_ref, subscription}] = MatchIndex.subs_for(__MODULE__.CountedRow)
    assert subscription.attrs == [page_key: "shared"]

    create!(__MODULE__.CountedRow, %{page_key: "shared"})
    assert await_record(session_id, updates).counted == 2
  end

  test "an aggregate over an unrelated resource subscribes to that resource" do
    {session_id, updates} = mount_and_stream()

    assert [{_ref, subscription}] = MatchIndex.subs_for(__MODULE__.LooseRow)
    assert subscription.attrs == []

    create!(__MODULE__.LooseRow, %{page_key: "shared"})
    assert await_record(session_id, updates).loose_count == 2
  end

  test "a calculation over a calculation subscribes to the inner calculation's rows" do
    {session_id, updates} = mount_and_stream()

    assert [{_ref, _subscription}] = MatchIndex.subs_for(__MODULE__.NestedRow)

    create!(__MODULE__.NestedRow, %{page_key: "shared", body: "m"})
    assert await_record(session_id, updates).outer_digest == "<m|n>"
  end

  test "a resource the page never reads is not subscribed" do
    {_session_id, updates} = mount_and_stream()

    assert MatchIndex.subs_for(__MODULE__.StrangerRow) == []
    create!(__MODULE__.StrangerRow, %{page_key: "shared"})
    assert Task.yield(updates, 100) == nil
    Task.shutdown(updates, :brutal_kill)
  end
end
