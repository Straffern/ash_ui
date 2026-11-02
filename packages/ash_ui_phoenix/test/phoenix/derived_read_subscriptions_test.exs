defmodule AshUi.Phoenix.DerivedReadSubscriptionsTest do
  @moduledoc """
  "Whatever a page reads, it subscribes to." A page that renders a DERIVED
  value — a module calculation whose `load/3` names a relationship, an
  aggregate over a relationship, an aggregate over an unrelated resource, or a
  calculation built on another calculation — must be subscribed to the rows
  that value is computed from, even though Ash loads those dependencies as
  hidden internal loads that never appear on the rendered record.

  Every case goes through the real connected mount (no hand-registered
  subscriptions): a foreign write to a dependency row must notify the page and
  repaint the derived value; a write to a resource the page never reads must
  not.
  """

  use ExUnit.Case, async: false

  alias AshUi.Notification.MatchIndex

  defmodule DigestRow do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:conversation_id, :uuid, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:conversation_id, :body])
      end
    end
  end

  defmodule CountedRow do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:conversation_id, :uuid, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:conversation_id])
      end
    end
  end

  defmodule NestedRow do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:conversation_id, :uuid, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:conversation_id, :body])
      end
    end
  end

  # Reached only through an UNRELATED aggregate (no relationship edge). Ash
  # authorizes an unrelated aggregate's query against its resource's domain,
  # so this one fixture lives in a real domain.
  defmodule LooseRow do
    @moduledoc false
    use Ash.Resource,
      domain: AshUi.Phoenix.DerivedReadSubscriptionsTest.LooseDomain,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:conversation_id, :uuid, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:conversation_id])
      end
    end
  end

  defmodule LooseDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshUi.Phoenix.DerivedReadSubscriptionsTest.LooseRow)
    end
  end

  # Never read by the page in any way.
  defmodule StrangerRow do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:conversation_id, :uuid, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        primary?(true)
        accept([:conversation_id])
      end
    end
  end

  defmodule Digest do
    @moduledoc false
    # Module calculation: `load/3` is its whole dependency declaration.
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
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:conversation_id, :uuid, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :digest_rows, AshUi.Phoenix.DerivedReadSubscriptionsTest.DigestRow do
        source_attribute(:conversation_id)
        destination_attribute(:conversation_id)
      end

      has_many :counted_rows, AshUi.Phoenix.DerivedReadSubscriptionsTest.CountedRow do
        source_attribute(:conversation_id)
        destination_attribute(:conversation_id)
      end

      has_many :nested_rows, AshUi.Phoenix.DerivedReadSubscriptionsTest.NestedRow do
        source_attribute(:conversation_id)
        destination_attribute(:conversation_id)
      end
    end

    actions do
      defaults([:read, :destroy])

      create :mount do
        argument(:conversation_id, :uuid, allow_nil?: false)
        change(set_attribute(:conversation_id, arg(:conversation_id)))
      end
    end

    aggregates do
      count(:counted, :counted_rows)

      count :loose_count, AshUi.Phoenix.DerivedReadSubscriptionsTest.LooseRow do
        filter(expr(conversation_id == parent(conversation_id)))
      end
    end

    calculations do
      calculate(
        :digest,
        :string,
        {AshUi.Phoenix.DerivedReadSubscriptionsTest.Digest, rel: :digest_rows}
      )

      calculate(
        :inner_digest,
        :string,
        {AshUi.Phoenix.DerivedReadSubscriptionsTest.Digest, rel: :nested_rows}
      )

      # Nested: the rendered calc depends only on another calculation.
      calculate(:outer_digest, :string, expr("<" <> inner_digest <> ">"))

      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [part: :derived_root], [
            inline(:digest, [part: :derived_digest], [text(digest)]),
            inline(:counted, [part: :derived_counted], [text(counted)]),
            inline(:loose, [part: :derived_loose], [text(loose_count)]),
            inline(:outer, [part: :derived_outer], [text(outer_digest)])
          ])
        )
      )
    end
  end

  @resources [DigestRow, CountedRow, NestedRow, LooseRow, StrangerRow, Page]

  setup do
    MatchIndex.reset()
    on_exit(fn -> Enum.each(@resources, &Ash.DataLayer.Ets.stop/1) end)
    :ok
  end

  defp create!(resource, attrs) do
    resource
    |> Ash.Changeset.for_create(:create, attrs,
      domain: Ash.Resource.Info.domain(resource) || AshUi.AshDomainFallback
    )
    |> Ash.create!()
  end

  # The connected mount path: a transport pid makes `connected?/1` true and
  # the `$callers` entry resolves the session pid to this process, so the
  # mount registers its subscriptions exactly as a live LiveView does.
  defp mount_page do
    session_id = Ash.UUID.generate()
    conversation_id = Ash.UUID.generate()

    create!(DigestRow, %{conversation_id: conversation_id, body: "a"})
    create!(CountedRow, %{conversation_id: conversation_id})
    create!(NestedRow, %{conversation_id: conversation_id, body: "n"})
    create!(LooseRow, %{conversation_id: conversation_id})

    Process.put(:"$callers", [self()])

    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}},
      private: %{}
    }

    {:ok, socket} =
      AshUi.Phoenix.mount(
        Page,
        %{"conversation_id" => conversation_id},
        %{"ash_ui_session_id" => session_id},
        socket,
        otp_app: :ash_ui_phoenix
      )

    record = socket.assigns.ash_ui_record
    assert record.digest == "a"
    assert record.counted == 1
    assert record.loose_count == 1
    assert record.outer_digest == "<n>"

    # The derived dependencies are hidden internal loads: nothing is on the
    # rendered record for a relationship walk to see.
    assert %Ash.NotLoaded{} = record.digest_rows
    assert %Ash.NotLoaded{} = record.counted_rows
    assert %Ash.NotLoaded{} = record.nested_rows

    socket
  end

  defp deliver!(socket) do
    assert_receive {:ash_ui_notification, _ref, _event} = notification, 500
    {:noreply, socket} = AshUi.Phoenix.runtime_handle_info(notification, socket)
    socket.assigns.ash_ui_record
  end

  test "a module calculation's load/3 relationship is subscribed key-matched" do
    socket = mount_page()
    record = socket.assigns.ash_ui_record

    assert [{_ref, subscription}] = MatchIndex.subs_for(DigestRow)
    assert subscription.attrs == [conversation_id: record.conversation_id]

    # A row of a different conversation is not this page's dependency.
    create!(DigestRow, %{conversation_id: Ash.UUID.generate(), body: "elsewhere"})
    refute_receive {:ash_ui_notification, _ref, _event}, 50

    create!(DigestRow, %{conversation_id: record.conversation_id, body: "b"})
    assert deliver!(socket).digest == "a|b"
  end

  test "an aggregate over a relationship is subscribed key-matched" do
    socket = mount_page()
    record = socket.assigns.ash_ui_record

    assert [{_ref, subscription}] = MatchIndex.subs_for(CountedRow)
    assert subscription.attrs == [conversation_id: record.conversation_id]

    create!(CountedRow, %{conversation_id: Ash.UUID.generate()})
    refute_receive {:ash_ui_notification, _ref, _event}, 50

    create!(CountedRow, %{conversation_id: record.conversation_id})
    assert deliver!(socket).counted == 2
  end

  test "an aggregate over an unrelated resource subscribes to that resource" do
    socket = mount_page()
    record = socket.assigns.ash_ui_record

    # No relationship key is derivable: a resource-level subscription.
    assert [{_ref, subscription}] = MatchIndex.subs_for(LooseRow)
    assert subscription.attrs == []

    create!(LooseRow, %{conversation_id: record.conversation_id})
    assert deliver!(socket).loose_count == 2
  end

  test "a calculation over a calculation subscribes to the inner calculation's rows" do
    socket = mount_page()
    record = socket.assigns.ash_ui_record

    assert [{_ref, subscription}] = MatchIndex.subs_for(NestedRow)
    assert subscription.attrs == [conversation_id: record.conversation_id]

    create!(NestedRow, %{conversation_id: record.conversation_id, body: "m"})
    assert deliver!(socket).outer_digest == "<m|n>"
  end

  test "a resource the page never reads is not subscribed" do
    socket = mount_page()
    record = socket.assigns.ash_ui_record

    assert MatchIndex.subs_for(StrangerRow) == []

    create!(StrangerRow, %{conversation_id: record.conversation_id})
    refute_receive {:ash_ui_notification, _ref, _event}, 50
  end
end
