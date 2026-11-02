defmodule AshUi.DefectClass.DC23BlueprintDataLayerTest do
  use ExUnit.Case, async: false
  import Ash.Expr
  require Ash.Query
  @repo_root Path.expand("../..", __DIR__)
  @data_layer_path Path.join(@repo_root, "lib/ash_ui/data_layer.ex")
  @store_path Path.join(@repo_root, "lib/ash_ui/data_layer/store.ex")
  @socket_store_path Path.join(@repo_root, "lib/ash_ui/data_layer/store/socket.ex")
  @explicit_sessions_path Path.join(
                            @repo_root,
                            "lib/ash_ui/verifiers/explicit_sessions.ex"
                          )

  defp unique_module(parts) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    Module.concat([__MODULE__ | parts] ++ [suffix])
  end

  defmodule TestNotifier do
    use Ash.Notifier
    @impl true
    def notify(%Ash.Notifier.Notification{actor: actor} = notification) when is_pid(actor) do
      send(actor, {:ash_notification, notification})
    end

    def notify(_notification) do
      :ok
    end
  end

  defmodule SocketPage do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    ash_ui do
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:title, :string, public?: true, default: "")
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create(:create) do
        primary?(true)
        accept([:title])
      end

      update(:rename) do
        argument(:title, :string, allow_nil?: false)
        change(set_attribute(:title, arg(:title)))
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text("socket")))
    end
  end

  defmodule EtsPage do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false,
      notifiers: [TestNotifier]

    ets do
      private?(true)
    end

    ash_ui do
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:title, :string, public?: true, default: "")
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update(:rename) do
        argument(:title, :string, allow_nil?: false)
        change(set_attribute(:title, arg(:title)))
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text("ets")))
    end
  end

  setup do
    Ash.DataLayer.Ets.stop(EtsPage, "org")
    :ok
  end

  test "stock ETS capabilities and explicit AshUi session declarations are honest" do
    assert Ash.DataLayer.data_layer_can?(SocketPage, :create)
    assert Ash.DataLayer.data_layer_can?(SocketPage, :read)
    assert Ash.DataLayer.data_layer_can?(SocketPage, :update)
    assert Ash.DataLayer.data_layer_can?(SocketPage, :destroy)
    assert Ash.DataLayer.data_layer_can?(SocketPage, :filter)
    assert Ash.DataLayer.data_layer_can?(SocketPage, :sort)
    assert Ash.DataLayer.data_layer_can?(SocketPage, :limit)
    assert Ash.DataLayer.data_layer_can?(SocketPage, {:filter_expr, Ash.Query.Ref})
    refute Ash.DataLayer.data_layer_can?(SocketPage, :transact)
    assert Ash.DataLayer.data_layer_can?(SocketPage, :upsert)
    assert Ash.DataLayer.data_layer_can?(SocketPage, {:atomic, :upsert})
    assert Ash.DataLayer.data_layer_can?(SocketPage, {:aggregate, :count})
    assert Ash.DataLayer.data_layer_can?(SocketPage, {:query_aggregate, :count})
    assert Ash.DataLayer.data_layer_can?(EtsPage, :upsert)
    assert Ash.DataLayer.data_layer_can?(EtsPage, {:atomic, :update})
    assert Ash.DataLayer.data_layer_can?(EtsPage, {:aggregate, :count})
    assert Ash.DataLayer.data_layer_can?(EtsPage, {:query_aggregate, :count})
    refute Ash.DataLayer.data_layer_can?(EtsPage, :transact)
    assert Ash.DataLayer.Ets.Info.private?(EtsPage)
    assert Ash.Resource.Info.multitenancy_strategy(EtsPage) == :context
    assert Ash.Resource.Info.multitenancy_global?(EtsPage)
    identity = Ash.Resource.Info.identity(EtsPage, :session_instance)
    assert identity.keys == [:session_id]
    assert identity.pre_check_with == AshUi.AshDomainFallback
  end

  test "ExplicitSessions verifies every stock ETS entity resource and rejects nil-able sessions" do
    verifier_source = File.read!(@explicit_sessions_path)
    refute verifier_source =~ "ash_ui_target_mode"
    refute verifier_source =~ "data_layer_backend"

    missing_session = unique_module([MissingSessionEntity])

    missing_error =
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule #{inspect(missing_session)} do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshUi],
            validate_domain_inclusion?: false

          ets do
            private?(true)
          end

          ash_ui do
          end

          attributes do
            attribute(:title, :string, public?: true)
          end

          calculations do
            calculate(:view, AshUi.Type.RenderTree, expr(text("missing")))
          end
        end
        """)
      end

    assert Exception.message(missing_error) =~ "must explicitly declare `attribute :session_id`"

    nilable_session = unique_module([NilableSessionEntity])

    nilable_error =
      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule #{inspect(nilable_session)} do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshUi],
            validate_domain_inclusion?: false

          ets do
            private?(true)
          end

          ash_ui do
          end

          attributes do
            attribute(:id, :uuid, allow_nil?: false, primary_key?: true, public?: false)
            attribute(:session_id, :string, allow_nil?: true, public?: false)
          end

          identities do
            identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
          end

          calculations do
            calculate(:view, AshUi.Type.RenderTree, expr(text("nilable")))
          end
        end
        """)
      end

    assert Exception.message(nilable_error) =~ "with `allow_nil?: false`"

    compliant = unique_module([CompliantSessionEntity])

    compiled =
      Code.compile_string("""
      defmodule #{inspect(compliant)} do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshUi],
          validate_domain_inclusion?: false

        ets do
          private?(true)
        end

        ash_ui do
        end

        attributes do
          attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
        end

        identities do
          identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
        end

        calculations do
          calculate(:view, AshUi.Type.RenderTree, expr(text("ok")))
        end
      end
      """)

    assert Enum.any?(compiled, fn {module, _bytecode} -> module == compliant end)
  end

  test "stock ETS round-trips rows and populates the declared session identity from Ash context" do
    context = %{session: %{session_id: "ets-create"}}

    {:ok, row} =
      SocketPage
      |> Ash.Changeset.for_create(:create, %{title: "created"},
        domain: AshUi.AshDomainFallback,
        context: context
      )
      |> Ash.create(authorize?: false, domain: AshUi.AshDomainFallback)

    assert row.session_id == "ets-create"

    query =
      SocketPage
      |> Ash.Query.filter(expr(session_id == "ets-create"))

    assert {:ok, [%SocketPage{title: "created"}]} =
             Ash.read(query, authorize?: false, domain: AshUi.AshDomainFallback)

    assert {:ok, [_row]} =
             Ash.read(SocketPage, authorize?: false, domain: AshUi.AshDomainFallback)
  end

  test "mount seeds ETS rows, get-by-session works, and observers see row notifications" do
    session_id = "ets-session-#{System.unique_integer([:positive])}"

    record =
      EtsPage
      |> Ash.Changeset.for_create(:mount, %{title: "mounted"},
        domain: AshUi.AshDomainFallback,
        authorize?: false,
        tenant: "org",
        actor: self(),
        context: %{session: %{session_id: session_id}}
      )
      |> Ash.create!()

    assert record.session_id == session_id

    assert {:ok, %EtsPage{title: "mounted"}} =
             Ash.get(EtsPage, %{session_id: session_id},
               tenant: "org",
               authorize?: false,
               domain: AshUi.AshDomainFallback
             )

    updated =
      record
      |> Ash.Changeset.for_update(:rename, %{"title" => "updated"},
        domain: AshUi.AshDomainFallback,
        authorize?: false,
        tenant: "org",
        actor: self()
      )
      |> Ash.update!()

    assert updated.title == "updated"

    assert_receive {:ash_notification,
                    %Ash.Notifier.Notification{
                      data: %EtsPage{title: "updated"},
                      action: %{name: :rename}
                    }}

    assert {:ok, %EtsPage{title: "updated"}} =
             Ash.get(EtsPage, %{session_id: session_id},
               tenant: "org",
               authorize?: false,
               domain: AshUi.AshDomainFallback
             )
  end

  test "ETS cleanup destroys dead session rows and sweep leaves live sessions alone" do
    dead_session_id = "dead-#{System.unique_integer([:positive])}"
    live_session_id = "live-#{System.unique_integer([:positive])}"

    mount = fn session_id, title ->
      EtsPage
      |> Ash.Changeset.for_create(:mount, %{title: title},
        domain: AshUi.AshDomainFallback,
        authorize?: false,
        tenant: "org",
        context: %{session: %{session_id: session_id}}
      )
      |> Ash.create!()
    end

    mount.(dead_session_id, "dead")
    mount.(live_session_id, "live")

    assert :ok = AshUi.Session.cleanup_session([EtsPage], dead_session_id, tenant: "org")

    assert {:error, _error} =
             Ash.get(EtsPage, %{session_id: dead_session_id},
               tenant: "org",
               authorize?: false,
               domain: AshUi.AshDomainFallback
             )

    assert {:ok, %EtsPage{title: "live"}} =
             Ash.get(EtsPage, %{session_id: live_session_id},
               tenant: "org",
               authorize?: false,
               domain: AshUi.AshDomainFallback
             )

    sweep_dead_session_id = "sweep-dead-#{System.unique_integer([:positive])}"

    mount.(sweep_dead_session_id, "sweep-dead")

    assert :ok =
             AshUi.Session.sweep_sessions([EtsPage], [live_session_id], tenant: "org")

    assert {:ok, %EtsPage{title: "live"}} =
             Ash.get(EtsPage, %{session_id: live_session_id},
               tenant: "org",
               authorize?: false,
               domain: AshUi.AshDomainFallback
             )

    assert {:error, _error} =
             Ash.get(EtsPage, %{session_id: sweep_dead_session_id},
               tenant: "org",
               authorize?: false,
               domain: AshUi.AshDomainFallback
             )
  end

  test "the custom operation executor and AshUi storage layers stay deleted" do
    refute File.exists?(Path.join(@repo_root, "lib/ash_ui/operation_executor.ex"))
    refute File.exists?(@data_layer_path)
    refute File.exists?(@store_path)
    refute File.exists?(@socket_store_path)
  end
end
