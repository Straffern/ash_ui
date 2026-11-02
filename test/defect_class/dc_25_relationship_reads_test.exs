defmodule AshUi.DefectClass.DC25RelationshipReadsTest do
  use ExUnit.Case, async: false

  defp message_fields(rows) do
    Enum.map(rows, &Map.take(&1, [:id, :conversation_id, :body, :seq]))
  end

  defmodule CaptureContextPreparation do
    use Ash.Resource.Preparation
    @impl true
    def prepare(query, _opts, context) do
      if is_pid(context.actor) do
        send(context.actor, {:relationship_read_context, context.actor, context.tenant})
      end

      query
    end
  end

  defmodule MessageSocket do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:conversation_id, :string, public?: true)
      attribute(:body, :string, public?: true)
      attribute(:seq, :integer, public?: true)
    end

    actions do
      read(:list_for_conversation) do
        prepare(CaptureContextPreparation)
      end
    end
  end

  defmodule RelationshipPage do
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
      attribute(:conversation_id, :string, public?: true)
      attribute(:last_seq, :integer, default: 0, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:messages, MessageSocket) do
        no_attributes?(true)
        read_action(:list_for_conversation)
        filter(expr(conversation_id == parent(conversation_id)))
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text("relationship page")))
    end
  end

  defmodule HandDeclaredRelationshipPage do
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
      attribute(:conversation_id, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:messages, MessageSocket) do
        no_attributes?(true)
        read_action(:list_for_conversation)
        filter(expr(conversation_id == parent(conversation_id)))
      end
    end

    actions do
      update(:reload_messages) do
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(each(messages, :message, [], [text(message.body)]))
      )
    end
  end

  defmodule ParamDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshUi.DefectClass.DC25RelationshipReadsTest.ParamMessage)
    end
  end

  defmodule ParamMessage do
    use Ash.Resource,
      domain: ParamDomain,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:conversation_id, :string, public?: true)
      attribute(:body, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule AggregateDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(AshUi.DefectClass.DC25RelationshipReadsTest.Member)
      resource(AshUi.DefectClass.DC25RelationshipReadsTest.NotifiedMember)
    end
  end

  defmodule Member do
    use Ash.Resource,
      domain: AggregateDomain,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:conversation_id, :string, public?: true)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule NotifiedMember do
    use Ash.Resource,
      domain: AggregateDomain,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false,
      notifiers: [AshUi.Notifier]

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:conversation_id, :string, public?: true)
      attribute(:name, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule ParamPage do
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
      attribute(:conversation_id, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:messages, ParamMessage) do
        no_attributes?(true)
        read_action(:read)
        filter(expr(conversation_id == parent(conversation_id)))
        sort(body: :desc)
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text("param page")))
    end
  end

  defmodule LoweredReadPage do
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
      attribute(:conversation_id, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:messages, ParamMessage) do
        no_attributes?(true)
        read_action(:read)
        filter(expr(conversation_id == parent(conversation_id)))
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text("lowered page")))
    end
  end

  defmodule AggregatePage do
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
      attribute(:conversation_id, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:members, Member) do
        source_attribute(:conversation_id)
        destination_attribute(:conversation_id)
        read_action(:read)
      end
    end

    aggregates do
      count(:member_count, :members)
    end

    calculations do
      calculate(:has_members?, :boolean, expr(exists(members, not is_nil(id))), public?: true)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text("aggregate page")))
    end
  end

  defmodule NotifierPage do
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
      attribute(:conversation_id, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:members, NotifiedMember) do
        no_attributes?(true)
        read_action(:read)
        filter(expr(conversation_id == parent(conversation_id)))
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text("notifier page")))
    end
  end

  setup do
    AshUi.Notification.MatchIndex.reset()
    Ash.DataLayer.Ets.stop(AggregatePage)
    Ash.DataLayer.Ets.stop(Member)
    Ash.DataLayer.Ets.stop(NotifiedMember)
    :ok
  end

  test "relationship read loads through Ash.load with actor and tenant" do
    Ash.DataLayer.Ets.stop(MessageSocket)

    row =
      Ash.Seed.seed!(
        MessageSocket,
        %{id: 1, conversation_id: "c1", body: "hello", seq: 1},
        tenant: "tenant-1"
      )

    page =
      Ash.Seed.seed!(
        RelationshipPage,
        %{session_id: Ash.UUID.generate(), conversation_id: "c1"},
        tenant: "tenant-1"
      )

    loaded =
      Ash.load!(page, :messages,
        domain: AshUi.AshDomainFallback,
        authorize?: false,
        actor: self(),
        tenant: "tenant-1"
      )

    assert message_fields(loaded.messages) == [
             Map.take(row, [:id, :conversation_id, :body, :seq])
           ]

    test_pid = self()
    assert_received {:relationship_read_context, ^test_pid, "tenant-1"}
  end

  test "match-index duplicate registration is idempotent for a read session" do
    ref = {:ash_ui_read, self(), [], :messages}

    subscription = %{
      pid: self(),
      resource: MessageSocket,
      attrs: [conversation_id: "c1"],
      tenant: nil
    }

    AshUi.Notification.MatchIndex.register(ref, subscription)
    AshUi.Notification.MatchIndex.register(ref, subscription)

    assert [%{subscription_ref: ^ref}] =
             AshUi.Notification.MatchIndex.lookup(MessageSocket, :conversation_id, "c1")
  end

  test "match-index re-register removes the old parent value entry" do
    ref = {:ash_ui_read, self(), [], :messages}

    AshUi.Notification.MatchIndex.register(ref, %{
      pid: self(),
      resource: MessageSocket,
      attrs: [conversation_id: "c1"],
      tenant: nil
    })

    AshUi.Notification.MatchIndex.reregister(ref, %{
      pid: self(),
      resource: MessageSocket,
      attrs: [conversation_id: "c2"],
      tenant: nil
    })

    assert [] = AshUi.Notification.MatchIndex.lookup(MessageSocket, :conversation_id, "c1")

    assert [%{subscription_ref: ^ref}] =
             AshUi.Notification.MatchIndex.lookup(MessageSocket, :conversation_id, "c2")
  end

  test "hand-declared relationship reads compile, render, and reload" do
    Ash.DataLayer.Ets.stop(MessageSocket)
    resource = AshUi.compile!(HandDeclaredRelationshipPage)

    assert [
             %{
               name: :messages,
               read_action: :list_for_conversation
             }
           ] = resource.relationships

    refute Map.has_key?(Map.from_struct(resource), :reads)

    assert [%{name: :reload_messages, type: :update}] =
             Enum.filter(resource.actions, &(&1.name == :reload_messages))

    page =
      Ash.Seed.seed!(HandDeclaredRelationshipPage, %{
        session_id: Ash.UUID.generate(),
        conversation_id: "c1"
      })

    first = Ash.Seed.seed!(MessageSocket, %{id: 1, conversation_id: "c1", body: "hello", seq: 1})

    loaded =
      Ash.load!(page, :messages, domain: AshUi.AshDomainFallback, authorize?: false)

    assert message_fields(loaded.messages) == [
             Map.take(first, [:id, :conversation_id, :body, :seq])
           ]

    assert {:ok, %{kind: :fragment, children: [%{kind: :text, content: "hello"}]}} =
             AshUi.Runtime.Rendering.render_view(resource, loaded, %{})

    # reload is the correctness path: new rows appear on the next load
    second = Ash.Seed.seed!(MessageSocket, %{id: 2, conversation_id: "c1", body: "again", seq: 2})

    reloaded =
      Ash.load!(page, :messages, domain: AshUi.AshDomainFallback, authorize?: false)

    assert Map.take(second, [:id, :conversation_id, :body, :seq]) in message_fields(
             reloaded.messages
           )
  end

  test "scoped reload refreshes only the selected relationship correctness path" do
    Ash.DataLayer.Ets.stop(MessageSocket)
    conversation_id = "scope-#{System.unique_integer([:positive])}"

    page =
      Ash.Seed.seed!(HandDeclaredRelationshipPage, %{
        session_id: Ash.UUID.generate(),
        conversation_id: conversation_id
      })

    first =
      Ash.Seed.seed!(MessageSocket, %{
        id: 1,
        conversation_id: conversation_id,
        body: "first",
        seq: 1
      })

    loaded =
      Ash.load!(page, :messages, domain: AshUi.AshDomainFallback, authorize?: false)

    assert message_fields(loaded.messages) == [
             Map.take(first, [:id, :conversation_id, :body, :seq])
           ]

    second =
      Ash.Seed.seed!(MessageSocket, %{
        id: 2,
        conversation_id: conversation_id,
        body: "second",
        seq: 2
      })

    assert {:ok, scoped} =
             AshUi.reload_scope(loaded, [:messages],
               domain: AshUi.AshDomainFallback,
               authorize?: false
             )

    assert Enum.sort(message_fields(scoped.messages)) ==
             Enum.sort([
               Map.take(first, [:id, :conversation_id, :body, :seq]),
               Map.take(second, [:id, :conversation_id, :body, :seq])
             ])
  end

  test "relationship aggregates and exists calculations load through Ash and render" do
    conversation_id = "aggregate-#{System.unique_integer([:positive])}"
    Ash.create!(Member, %{conversation_id: conversation_id, name: "Ada"}, domain: AggregateDomain)

    Ash.create!(Member, %{conversation_id: conversation_id, name: "Grace"},
      domain: AggregateDomain
    )

    page =
      Ash.Seed.seed!(AggregatePage, %{
        session_id: Ash.UUID.generate(),
        conversation_id: conversation_id
      })

    assert {:ok, loaded_root} =
             Ash.load(page, [:member_count, :has_members?],
               authorize?: false,
               domain: AshUi.AshDomainFallback
             )

    assert Map.get(loaded_root, :member_count) == 2
    assert Map.get(loaded_root, :has_members?) == true

    assert {:ok, tree} =
             AshUi.Runtime.Rendering.render_tree(
               AshUi.Runtime.ResourceInfo.compiled_resource(AggregatePage),
               loaded_root,
               %{}
             )

    {:safe, iodata} = AshUi.RenderTarget.Html.render_static(tree)
    html = IO.iodata_to_binary(iodata)
    assert html =~ "aggregate page"
  end

  test "AshUi.Notifier notifications drive native relationship reads end to end" do
    conversation_id = "notify-#{System.unique_integer([:positive])}"

    page =
      Ash.Seed.seed!(NotifierPage, %{
        session_id: Ash.UUID.generate(),
        conversation_id: conversation_id
      })

    subscription_ref = {:ash_ui_read, self(), [], :members}

    AshUi.Notification.MatchIndex.register(subscription_ref, %{
      pid: self(),
      resource: NotifiedMember,
      attrs: [conversation_id: conversation_id],
      tenant: nil
    })

    Ash.create!(NotifiedMember, %{conversation_id: conversation_id, name: "Ada"},
      domain: AggregateDomain
    )

    # the notification is the latency hint; reload is the correctness path
    assert_receive {:ash_ui_notification, ^subscription_ref, _event}

    reloaded =
      Ash.load!(page, :members, domain: AshUi.AshDomainFallback, authorize?: false)

    assert [%NotifiedMember{name: "Ada"}] = reloaded.members
  end

  test "relationships need no AshUi read marker" do
    refute function_exported?(AshUi, :relationship_read, 0)
    refute function_exported?(AshUi, :relationship_read, 1)
  end

  test "ordinary Ash relationship filters and sorts load directly" do
    unique = "p-#{System.unique_integer([:positive])}"
    Ash.create!(ParamMessage, %{conversation_id: unique, body: "a"})
    Ash.create!(ParamMessage, %{conversation_id: unique, body: "z"})
    resource = AshUi.compile!(ParamPage)
    assert [%{name: :messages, sort: [body: :desc]} = relationship] = resource.relationships
    refute Map.has_key?(relationship, :parametrized?)

    page =
      Ash.Seed.seed!(ParamPage, %{session_id: Ash.UUID.generate(), conversation_id: unique})

    loaded =
      Ash.load!(page, :messages, domain: AshUi.AshDomainFallback, authorize?: false)

    assert [%ParamMessage{body: "a"}, %ParamMessage{body: "z"}] =
             Enum.sort_by(loaded.messages, & &1.body)
  end

  test "plain relationship read artifacts and nil parent loads nothing" do
    resource = AshUi.compile!(LoweredReadPage)

    assert [
             %{
               name: :messages,
               read_action: :read,
               no_attributes?: true,
               required_parent_attrs: [:conversation_id]
             } = relationship
           ] = resource.relationships

    refute Map.has_key?(relationship, :read?)

    page =
      Ash.Seed.seed!(LoweredReadPage, %{session_id: Ash.UUID.generate(), conversation_id: nil})

    loaded =
      Ash.load!(page, :messages, domain: AshUi.AshDomainFallback, authorize?: false)

    assert loaded.messages == []
  end
end
