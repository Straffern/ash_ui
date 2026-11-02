defmodule AshUi.Notification.SessionRowGcTest do
  # Crash-path GC: rows created by a session process are destroyed when
  # that process dies without orderly teardown.
  use ExUnit.Case, async: false

  alias AshUi.Notification.MatchIndex
  require Ash.Query

  defmodule GcProbe do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private?(false)
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:session_id, :uuid, allow_nil?: false, public?: true)
      attribute(:subject, :string, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id, :subject],
        pre_check_with: AshUi.AshDomainFallback
      )
    end

    relationships do
      has_many :same_subject, GcProbe do
        source_attribute(:subject)
        destination_attribute(:subject)
        filter(expr(subject == parent(subject)))
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(section(:root, [], [text(subject)])))
    end

    actions do
      defaults([:read, :destroy])

      create :mount do
        accept([:subject])
      end
    end
  end

  test "rows are destroyed when the creating session process dies" do
    MatchIndex.reset()
    session_id = Ash.UUID.generate()
    parent = self()

    pid =
      spawn(fn ->
        GcProbe
        |> Ash.Changeset.for_create(:mount, %{subject: "fold-a"},
          context: %{
            session_id: session_id,
            shared: %{ash_ui_session_pid: self()}
          },
          authorize?: false,
          domain: AshUi.AshDomainFallback.ensure!(GcProbe)
        )
        |> Ash.create!(authorize?: false)

        send(parent, :created)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :created, 5_000

    domain = AshUi.AshDomainFallback.ensure!(GcProbe)
    assert [_row] = rows_for_session(domain, session_id)

    Process.exit(pid, :kill)
    Process.sleep(200)

    assert [] == rows_for_session(domain, session_id)
  end

  test "a short-lived Ash caller inherits the live session owner instead of stealing it" do
    MatchIndex.reset()
    session_id = Ash.UUID.generate()
    parent = self()

    owner =
      spawn(fn ->
        GcProbe
        |> Ash.Changeset.for_create(:mount, %{subject: "browser"},
          context: %{
            session_id: session_id,
            shared: %{ash_ui_session_pid: self()}
          },
          authorize?: false,
          domain: AshUi.AshDomainFallback.ensure!(GcProbe)
        )
        |> Ash.create!(authorize?: false)

        send(parent, :owner_created)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :owner_created, 5_000
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    Process.sleep(50)

    caller =
      spawn(fn ->
        GcProbe
        |> Ash.Changeset.for_create(:mount, %{subject: "ash-lua"},
          context: %{session_id: session_id},
          authorize?: false,
          domain: AshUi.AshDomainFallback.ensure!(GcProbe)
        )
        |> Ash.create!(authorize?: false)

        send(parent, {:caller_created, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:caller_created, ^caller}, 5_000
    ref = Process.monitor(caller)
    send(caller, :finish)
    assert_receive {:DOWN, ^ref, :process, ^caller, _reason}, 5_000
    Process.sleep(100)

    domain = AshUi.AshDomainFallback.ensure!(GcProbe)

    assert Enum.map(rows_for_session(domain, session_id), & &1.subject)
           |> Enum.sort() ==
             ["ash-lua", "browser"]

    Process.exit(owner, :kill)
    Process.sleep(200)

    assert [] == rows_for_session(domain, session_id)
  end

  test "transport death kills its Bridge owner, releases its fold, and sweeps session rows" do
    MatchIndex.reset()
    session_id = Ash.UUID.generate()
    parent = self()
    transport = spawn(fn -> receive do: (:close -> :ok) end)

    owner =
      spawn(fn ->
        fold = spawn_link(fn -> receive do: (:release -> :ok) end)
        MatchIndex.track_session_owner(transport, self())

        GcProbe
        |> Ash.Changeset.for_create(:mount, %{subject: "live-bridge"},
          context: %{
            session_id: session_id,
            shared: %{ash_ui_session_pid: transport}
          },
          authorize?: false,
          domain: AshUi.AshDomainFallback.ensure!(GcProbe)
        )
        |> Ash.create!(authorize?: false)

        send(parent, {:bridge_ready, self(), fold})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:bridge_ready, ^owner, fold}, 5_000
    owner_ref = Process.monitor(owner)
    fold_ref = Process.monitor(fold)
    transport_ref = Process.monitor(transport)
    domain = AshUi.AshDomainFallback.ensure!(GcProbe)

    assert_eventually(fn -> rows_for_session(domain, session_id) != [] end)
    Process.exit(transport, :kill)

    assert_receive {:DOWN, ^transport_ref, :process, ^transport, :killed}, 5_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_receive {:DOWN, ^fold_ref, :process, ^fold, :killed}, 5_000
    assert_eventually(fn -> rows_for_session(domain, session_id) == [] end)
  end

  test "Bridge owner death expires only its subscriptions without restarting the index" do
    MatchIndex.reset()
    transport = spawn(fn -> receive do: (:close -> :ok) end)
    owner = spawn(fn -> receive do: (:close -> :ok) end)

    on_exit(fn ->
      if Process.alive?(transport), do: Process.exit(transport, :kill)
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    owner_subscription = {:owner_subscription, make_ref()}
    survivor_subscription = {:survivor_subscription, make_ref()}

    MatchIndex.track_session_owner(transport, owner)

    MatchIndex.register(owner_subscription, %{
      pid: owner,
      resource: GcProbe,
      attrs: [subject: "owner"],
      filter: nil,
      parent: nil,
      reload_scope: [:same_subject],
      tenant: nil,
      domain: AshUi.AshDomainFallback
    })

    MatchIndex.register(survivor_subscription, %{
      pid: self(),
      resource: GcProbe,
      attrs: [subject: "survivor"],
      filter: nil,
      parent: nil,
      reload_scope: [:same_subject],
      tenant: nil,
      domain: AshUi.AshDomainFallback
    })

    assert_eventually(fn ->
      state = :sys.get_state(MatchIndex)

      MatchIndex.subscription(owner_subscription) != nil and
        MatchIndex.subscription(survivor_subscription) != nil and
        MapSet.member?(Map.fetch!(state.session_owners, transport), owner)
    end)

    index = Process.whereis(MatchIndex)
    index_ref = Process.monitor(index)
    owner_ref = Process.monitor(owner)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    refute_receive {:DOWN, ^index_ref, :process, ^index, _reason}, 200

    assert_eventually(fn -> MatchIndex.subscription(owner_subscription) == nil end)
    assert MatchIndex.subscription(survivor_subscription) != nil
    assert Process.whereis(MatchIndex) == index
  end

  test "transport death sweeps session rows from their tenant table" do
    MatchIndex.reset()
    session_id = Ash.UUID.generate()
    tenant = "session-row-gc-tenant"
    parent = self()
    transport = spawn(fn -> receive do: (:close -> :ok) end)

    owner =
      spawn(fn ->
        MatchIndex.track_session_owner(transport, self())

        GcProbe
        |> Ash.Changeset.for_create(:mount, %{subject: "tenanted-bridge"},
          context: %{
            session_id: session_id,
            shared: %{ash_ui_session_pid: transport}
          },
          tenant: tenant,
          authorize?: false,
          domain: AshUi.AshDomainFallback.ensure!(GcProbe)
        )
        |> Ash.create!(authorize?: false)

        send(parent, {:tenanted_bridge_ready, self()})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:tenanted_bridge_ready, ^owner}, 5_000
    owner_ref = Process.monitor(owner)
    domain = AshUi.AshDomainFallback.ensure!(GcProbe)

    assert_eventually(fn -> rows_for_session(domain, session_id, tenant) != [] end)
    Process.exit(transport, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_eventually(fn -> rows_for_session(domain, session_id, tenant) == [] end)
  end

  test "a Bridge mailbox above the fixed bound is terminated" do
    MatchIndex.reset()
    parent = self()
    transport = spawn(fn -> receive do: (:close -> :ok) end)

    owner =
      spawn(fn ->
        fold = spawn_link(fn -> receive do: (:release -> :ok) end)
        MatchIndex.track_session_owner(transport, self())
        send(parent, {:bridge_registered, self(), fold})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:bridge_registered, ^owner, fold}, 5_000
    owner_ref = Process.monitor(owner)
    fold_ref = Process.monitor(fold)

    assert_eventually(fn ->
      state = :sys.get_state(MatchIndex)
      MapSet.member?(Map.fetch!(state.session_owners, transport), owner)
    end)

    for message <- 0..MatchIndex.session_owner_mailbox_limit(), do: send(owner, {:stuck, message})

    assert {:message_queue_len, length} = Process.info(owner, :message_queue_len)
    assert length > MatchIndex.session_owner_mailbox_limit()
    assert :ok = MatchIndex.audit_session_owners()

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
    assert_receive {:DOWN, ^fold_ref, :process, ^fold, :killed}, 5_000

    Process.exit(transport, :kill)
  end

  test "session handoffs are one-shot and reset with the session runtime" do
    MatchIndex.reset()
    key = {:transport_phase, Ash.UUID.generate()}
    value = %{loaded: :snapshot}

    assert :ok = MatchIndex.put_session_handoff(key, value)
    assert ^value = MatchIndex.take_session_handoff(key)
    assert nil == MatchIndex.take_session_handoff(key)

    assert :ok = MatchIndex.put_session_handoff(key, value)
    assert :ok = MatchIndex.reset()
    assert nil == MatchIndex.take_session_handoff(key)
  end

  test "three concurrent mount handoffs stay below 50 ms when the index owner is saturated" do
    MatchIndex.reset()
    index = Process.whereis(MatchIndex)
    :ok = :sys.suspend(index)

    try do
      results =
        1..3
        |> Enum.map(fn mount ->
          Task.async(fn ->
            key = {:concurrent_mount, mount, Ash.UUID.generate()}
            value = %{mount: mount}
            started_at = System.monotonic_time(:microsecond)
            :ok = MatchIndex.put_session_handoff(key, value)
            ^value = MatchIndex.take_session_handoff(key)
            System.monotonic_time(:microsecond) - started_at
          end)
        end)
        |> Task.await_many(250)

      assert length(results) == 3
      assert Enum.all?(results, &(&1 < 50_000)), inspect(results)
    after
      :ok = :sys.resume(index)
    end
  end

  test "direct tables use the final public row shapes" do
    MatchIndex.reset()
    filter = Ash.Resource.Info.relationship(GcProbe, :same_subject).filter

    parent =
      %GcProbe{id: Ash.UUID.generate(), session_id: Ash.UUID.generate(), subject: "legacy"}
      |> Map.put(:same_subject, List.duplicate({:loaded_child, "payload"}, 1_000))

    subscription = %{
      pid: self(),
      resource: GcProbe,
      attrs: [subject: "legacy"],
      filter: filter,
      parent: parent,
      reload_scope: [:same_subject],
      tenant: nil,
      domain: AshUi.AshDomainFallback
    }

    ref = {:subscription, make_ref()}
    key = {:handoff, make_ref()}
    assert :ok = MatchIndex.register(ref, subscription)
    assert :ok = MatchIndex.put_session_handoff(key, :value)

    assert [{^ref, {stored, triple_keys, resource_attrs}}] =
             :ets.lookup(AshUi.Notification.MatchIndex.Subs, ref)

    assert triple_keys != []
    assert resource_attrs != []

    assert [{^key, order_key, :value}] =
             :ets.lookup(AshUi.Notification.MatchIndex.Handoffs, key)

    assert [{^order_key, ^key}] =
             :ets.lookup(AshUi.Notification.MatchIndex.HandoffOrder, order_key)

    assert stored.parent.subject == parent.subject
    assert match?(%Ash.NotLoaded{}, stored.parent.same_subject)
    assert :value == MatchIndex.take_session_handoff(key)
    assert [] == :ets.lookup(AshUi.Notification.MatchIndex.Handoffs, key)
    assert [] == :ets.lookup(AshUi.Notification.MatchIndex.HandoffOrder, order_key)

    for table <- [
          AshUi.Notification.MatchIndex.Triples,
          AshUi.Notification.MatchIndex.Subs,
          AshUi.Notification.MatchIndex.ResourceAttrs,
          AshUi.Notification.MatchIndex.Handoffs,
          AshUi.Notification.MatchIndex.HandoffOrder
        ] do
      assert :ets.info(table, :protection) == :public
    end
  end

  test "subscription storage is bounded by live refs and drops unrelated parent loads" do
    MatchIndex.reset()
    filter = Ash.Resource.Info.relationship(GcProbe, :same_subject).filter

    parent =
      %GcProbe{id: Ash.UUID.generate(), session_id: Ash.UUID.generate(), subject: "bounded"}
      |> Map.put(:same_subject, List.duplicate({:loaded_child, "payload"}, 100_000))

    subscription = %{
      pid: self(),
      resource: GcProbe,
      attrs: [subject: "bounded"],
      filter: filter,
      parent: parent,
      reload_scope: [:same_subject],
      tenant: nil,
      domain: AshUi.AshDomainFallback
    }

    ref = {:bounded_subscription, make_ref()}
    before_words = index_memory_words()

    for _notification <- 1..200 do
      assert :ok = MatchIndex.reregister(ref, subscription)
    end

    notification = %Ash.Notifier.Notification{
      resource: GcProbe,
      action: %{type: :update},
      data: %GcProbe{
        id: Ash.UUID.generate(),
        session_id: Ash.UUID.generate(),
        subject: "bounded"
      }
    }

    for _notification <- 1..2_000 do
      MatchIndex.dispatch(notification)
    end

    assert_receive {:ash_ui_notification, ^ref, _event}
    stored = MatchIndex.subscription(ref)
    after_words = index_memory_words()

    assert stored.parent.subject == parent.subject
    assert match?(%Ash.NotLoaded{}, stored.parent.same_subject)
    assert :ets.info(AshUi.Notification.MatchIndex.Subs, :size) == 1
    assert after_words - before_words < 50_000
  end

  test "filter evaluation defects fail open and log before delivering the reload hint" do
    MatchIndex.reset()
    ref = {:unevaluable_filter, make_ref()}

    MatchIndex.register(ref, %{
      pid: self(),
      resource: GcProbe,
      attrs: [subject: "filter-error"],
      filter: %Ash.Filter{
        resource: GcProbe,
        expression: %Ash.Query.Parent{expr: true}
      },
      parent: :invalid_parent_shape,
      reload_scope: [:same_subject],
      tenant: nil,
      domain: AshUi.AshDomainFallback
    })

    notification = %Ash.Notifier.Notification{
      resource: GcProbe,
      action: %{type: :create},
      data: %GcProbe{
        id: Ash.UUID.generate(),
        session_id: Ash.UUID.generate(),
        subject: "filter-error"
      }
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert [{^ref, _subscription}] = MatchIndex.dispatch(notification)
        assert_receive {:ash_ui_notification, ^ref, _event}
      end)

    assert log =~ "notification filter evaluation failed open"
    assert log =~ inspect(ref)
    assert log =~ inspect(GcProbe)
  end

  test "unfiltered relationship subscriptions compact into one exact indexed set" do
    MatchIndex.reset()

    base = %{
      pid: self(),
      resource: GcProbe,
      filter: nil,
      parent: nil,
      reload_scope: [:probes],
      tenant: nil,
      domain: AshUi.AshDomainFallback
    }

    [{ref, compacted}] =
      MatchIndex.compact_subscriptions(
        [
          {{:probe, 1}, Map.put(base, :attrs, subject: "one")},
          {{:probe, 2}, Map.put(base, :attrs, subject: "two")}
        ],
        {:session, "compact"}
      )

    assert compacted.attrs == [subject: {:one_of, ["one", "two"]}]
    assert :ok = MatchIndex.register(ref, compacted)

    assert [%{subscription_ref: ^ref}] = MatchIndex.lookup(GcProbe, :subject, "one")
    assert [%{subscription_ref: ^ref}] = MatchIndex.lookup(GcProbe, :subject, "two")
    assert [] = MatchIndex.lookup(GcProbe, :subject, "other")
  end

  defp rows_for_session(domain, session_id, tenant \\ nil) do
    query =
      GcProbe
      |> Ash.Query.filter(session_id == ^session_id)

    query = if tenant, do: Ash.Query.set_tenant(query, tenant), else: query

    query
    |> Ash.read!(authorize?: false, domain: domain)
  end

  defp index_memory_words do
    process_words =
      Process.info(Process.whereis(MatchIndex), :memory)
      |> elem(1)
      |> div(:erlang.system_info(:wordsize))

    table_words =
      [
        AshUi.Notification.MatchIndex.Triples,
        AshUi.Notification.MatchIndex.Subs,
        AshUi.Notification.MatchIndex.ResourceAttrs,
        AshUi.Notification.MatchIndex.Handoffs,
        AshUi.Notification.MatchIndex.HandoffOrder
      ]
      |> Enum.sum_by(&(:ets.info(&1, :memory) || 0))

    process_words + table_words
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())
end
