defmodule AshUi.Phoenix.ComposerDispatchRaceTest do
  use ExUnit.Case, async: false

  alias AshUi.Patch.Compiler
  alias AshUi.Phoenix, as: Bridge
  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveViewTest.Diff, as: Client

  defmodule ComposerPage do
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

      attribute(:composer_text, :string,
        allow_nil?: false,
        default: "",
        constraints: [allow_empty?: true],
        public?: true
      )

      attribute(:sent_text, :string,
        allow_nil?: false,
        default: "",
        constraints: [allow_empty?: true],
        public?: true
      )

      attribute(:sent_source, :string,
        allow_nil?: false,
        default: "",
        constraints: [allow_empty?: true],
        public?: true
      )
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
        accept([:session_id, :composer_text, :sent_text, :sent_source])
      end

      update :update_composer do
        require_atomic?(false)
        accept([:composer_text])
      end

      update :send do
        require_atomic?(false)
        accept([:composer_text])
        argument(:source, :string, default: "submit")

        change(fn changeset, _context ->
          text = Ash.Changeset.get_attribute(changeset, :composer_text)
          source = Ash.Changeset.get_argument(changeset, :source)

          if text in [nil, ""] do
            Ash.Changeset.add_error(changeset, "Messages cannot be blank.")
          else
            changeset
            |> Ash.Changeset.force_change_attribute(:sent_text, text)
            |> Ash.Changeset.force_change_attribute(:sent_source, source)
            |> Ash.Changeset.force_change_attribute(:composer_text, "")
          end
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          form(:composer, [on_submit: :send], [
            textarea(
              :composer_text,
              [
                name: :composer_text,
                value: composer_text,
                on_input: :update_composer,
                on_keydown: :send,
                when: key("Enter"),
                prevent_default: true
              ],
              []
            ),
            button(
              :click_send,
              [type: :button, on_click: :send, action_input: %{source: "click"}],
              [text("Click send")]
            ),
            button(:submit_send, [type: :submit], [text("Submit send")])
          ])
        )
      )
    end
  end

  defp socket do
    record =
      ComposerPage
      |> Ash.Changeset.for_create(
        :mount,
        %{
          session_id: Ash.UUID.generate(),
          composer_text: "",
          sent_text: "",
          sent_source: ""
        },
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )
      |> Ash.create!(domain: AshUi.AshDomainFallback)

    table = Compiler.table(ComposerPage, :view, target: AshUi.Phoenix.RenderTarget)

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        ash_ui_record: record,
        ash_ui_resource: ComposerPage,
        ash_ui_view: :view,
        ash_ui_tables: %{
          {ComposerPage, :view, AshUi.Phoenix.RenderTarget} => table
        },
        ash_ui_params: %{},
        ash_ui_session_id: record.session_id,
        ash_ui_actor: nil,
        ash_ui_location: "/composer"
      }
    }
  end

  defp html(socket) do
    rendered = Bridge.render_shell(socket.assigns)
    lv_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {diff, _prints, _components} =
      Diff.render(lv_socket, rendered, Diff.new_fingerprints(), Diff.new_components())

    %{}
    |> Client.merge_diff(diff)
    |> Map.delete(:streams)
    |> Diff.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp event!(socket, attribute) do
    [_, event] =
      Regex.run(
        ~r/#{Regex.escape(attribute)}="(ash_ui:dispatch:[^"]+)"/,
        html(socket)
      )

    event
  end

  test "submit uses the fresh named field when its input commit is still in flight" do
    socket = socket()
    submit = event!(socket, "phx-submit")
    input = event!(socket, "phx-change")

    assert socket.assigns.ash_ui_record.composer_text == ""

    {:noreply, sent} =
      Bridge.runtime_handle_event(submit, %{"composer_text" => "fresh submit"}, socket)

    assert sent.assigns.ash_ui_record.sent_text == "fresh submit"
    assert sent.assigns.ash_ui_record.composer_text == ""
    assert sent.assigns[:ash_ui_errors] in [nil, []]

    {:noreply, late_input} =
      Bridge.runtime_handle_event(
        input,
        %{"value" => "fresh submit", "composer_text" => "fresh submit"},
        sent
      )

    assert late_input.assigns.ash_ui_record.sent_text == "fresh submit"
  end

  test "submit uses the fresh named field when no input event ever arrives" do
    socket = socket()

    {:noreply, sent} =
      Bridge.runtime_handle_event(
        event!(socket, "phx-submit"),
        %{"composer_text" => "coalesced input"},
        socket
      )

    assert sent.assigns.ash_ui_record.sent_text == "coalesced input"
    assert sent.assigns.ash_ui_record.composer_text == ""
  end

  test "Enter keydown and a click action inside the form bind the fresh named field" do
    socket = socket()

    {:noreply, entered} =
      Bridge.runtime_handle_event(
        event!(socket, "phx-keydown"),
        %{
          "key" => "Enter",
          "value" => "fresh Enter",
          "composer_text" => "fresh Enter"
        },
        socket
      )

    assert entered.assigns.ash_ui_record.sent_text == "fresh Enter"
    assert entered.assigns.ash_ui_record.sent_source == "submit"

    {:noreply, clicked} =
      Bridge.runtime_handle_event(
        event!(entered, "phx-click"),
        %{"composer_text" => "fresh click"},
        entered
      )

    assert clicked.assigns.ash_ui_record.sent_text == "fresh click"
    assert clicked.assigns.ash_ui_record.sent_source == "click"
  end

  test "a failing send paints page error state without an authored errors expression" do
    socket = socket()

    {:noreply, failed} =
      Bridge.runtime_handle_event(
        event!(socket, "phx-submit"),
        %{"composer_text" => ""},
        socket
      )

    assert [_error | _rest] = failed.assigns.ash_ui_errors
    assert html(failed) =~ ~s(role="alert")
    assert html(failed) =~ "Messages cannot be blank."

    {:noreply, recovered} =
      Bridge.runtime_handle_event(
        event!(failed, "phx-submit"),
        %{"composer_text" => "valid after error"},
        failed
      )

    assert recovered.assigns.ash_ui_errors == []
    refute html(recovered) =~ ~s(data-ash-ui-error="page")
  end
end
