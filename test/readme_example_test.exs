defmodule AshUi.ReadmeExampleTest do
  @moduledoc """
  The README example, compiled and exercised. If this file changes, the
  README must change with it.
  """
  use ExUnit.Case, async: false

  defmodule Message do
    use Ash.Resource,
      domain: AshUi.ReadmeExampleTest.Mail,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier],
      authorizers: [Ash.Policy.Authorizer]

    policies do
      policy always() do
        authorize_if actor_present()
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :subject, :string, allow_nil?: false, public?: true
      create_timestamp :inserted_at
    end

    actions do
      defaults [:read]

      create :send do
        accept [:subject]
      end
    end
  end

  defmodule Mail do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshUi.ReadmeExampleTest.Message do
        define :send_message, action: :send, args: [:subject]
      end
    end
  end

  defmodule InboxScreen do
    use Ash.Resource,
      domain: AshUi.ReadmeExampleTest.Screens,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private? false
    end

    ash_ui do
      stylesheets ["test/support/assets/readme_inbox.css"]
    end

    routes do
      route "/inbox"
    end

    policies do
      policy always() do
        authorize_if actor_present()
      end
    end

    attributes do
      attribute :session_id, :uuid, allow_nil?: false, primary_key?: true
      attribute :selected_id, :uuid, public?: true
      attribute :draft, :string, public?: true
    end

    identities do
      identity :session_instance, [:session_id]
    end

    relationships do
      has_many :messages, AshUi.ReadmeExampleTest.Message do
        no_attributes? true
        sort inserted_at: :desc
      end
    end

    calculations do
      calculate :view,
                AshUi.Type.RenderTree,
                expr(
                  section(:inbox, [], [
                    list(:messages, [], [
                      each(messages, :message, [key: message.id], [
                        item(
                          :message_row,
                          [
                            state: [selected: message.id == selected_id],
                            on_click: :select,
                            action_input: %{id: message.id}
                          ],
                          [text(message.subject)]
                        )
                      ])
                    ]),
                    form(:composer, [on_submit: :send_draft], [
                      input(
                        :draft_input,
                        [
                          value: draft,
                          on_input: :edit_draft,
                          action_input: %{draft: event(:value)}
                        ],
                        []
                      ),
                      button(:send, [type: :submit], [text("Send")])
                    ])
                  ])
                )
    end

    actions do
      defaults [:read]

      create :mount

      update :select do
        argument :id, :uuid, allow_nil?: false
        change set_attribute(:selected_id, arg(:id))
      end

      update :edit_draft do
        accept [:draft]
      end

      update :send_draft do
        require_atomic? false
        validate present(:draft)

        change fn changeset, context ->
          Ash.Changeset.before_action(changeset, fn changeset ->
            AshUi.ReadmeExampleTest.Mail.send_message!(changeset.data.draft, scope: context)
            Ash.Changeset.force_change_attribute(changeset, :draft, nil)
          end)
        end
      end
    end
  end

  defmodule Screens do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshUi.ReadmeExampleTest.InboxScreen do
        define :mount_inbox, action: :mount
        define :select_message, action: :select, args: [:id]
        define :edit_draft, action: :edit_draft, args: [:draft]
        define :send_draft, action: :send_draft
      end
    end
  end

  @actor %{id: "user-1"}

  test "a screen is a resource: mount, render, act, re-render" do
    session_id = Ash.UUID.generate()

    screen =
      Screens.mount_inbox!(actor: @actor, context: %{session_id: session_id})

    assert screen.session_id == session_id

    screen = Screens.edit_draft!(screen, "Hello", actor: @actor)
    screen = Screens.send_draft!(screen, actor: @actor)
    assert screen.draft == nil

    [message] = Ash.read!(Message, actor: @actor)
    screen = Screens.select_message!(screen, message.id, actor: @actor)

    assert {:ok, tree} = Ash.calculate(screen, :view, actor: @actor)
    {:safe, iodata} = AshUi.RenderTarget.Html.render_static(tree)
    html = IO.iodata_to_binary(iodata)

    assert html =~ "Hello"
    assert html =~ ~s(aria-selected="true")
  end

  test "the README's custom expression list matches AshUi.Expressions.canonical/0" do
    readme = File.read!(Path.expand("../README.md", __DIR__))

    listed =
      Regex.scan(~r/^    (AshUi\.Expressions\.\w+),?$/m, readme)
      |> Enum.map(fn [_, name] -> Module.concat([name]) end)

    assert listed == AshUi.Expressions.canonical()
    assert AshUi.Expressions.canonical() -- Application.get_env(:ash, :custom_expressions) == []
  end

  test "the view is policy-checked like any other calculation" do
    screen =
      Screens.mount_inbox!(actor: @actor, context: %{session_id: Ash.UUID.generate()})

    assert {:error, %Ash.Error.Forbidden{}} = Ash.calculate(screen, :view, actor: nil)
  end
end
