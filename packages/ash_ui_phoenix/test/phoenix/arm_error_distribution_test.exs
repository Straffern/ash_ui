defmodule AshUi.Phoenix.ArmErrorDistributionTest do
  @moduledoc """
  Error distribution INSIDE branch arms, through the real bridge loop —
  the punch-list follow-through on first-class arm slots: a failed
  dispatch must find bound-field elements and error reads authored inside
  an `if` arm (they are ordinary table slots under `addr/t|f`), paint the
  error state, and clear it on the next success. A `when:`-gated binding
  whose guard rejects the event must leave error state untouched.
  """

  use ExUnit.Case, async: false

  alias AshUi.Notification.MatchIndex

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
      defaults([:read, :destroy])

      create(:mount)

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

      update :stop_editing do
        require_atomic?(false)
        change(set_attribute(:editing?, false))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [part: :arm_err_root], [
            if editing? do
              box(:editor, [part: :arm_err_editor], [
                form(:edit_form, [part: :arm_err_form], [
                  input(:title,
                    part: :arm_err_input,
                    name: :title,
                    value: title,
                    on_keydown: :save,
                    when: key("Enter")
                  )
                ]),
                if field_errors(:title) != [] do
                  paragraph(:title_error, [part: :arm_err_message], [text("title too short")])
                end,
                button(
                  :save_bad,
                  [
                    type: :button,
                    part: :arm_err_save_bad,
                    on_click: :save,
                    action_input: %{title: "x"}
                  ],
                  [text("save bad")]
                ),
                button(
                  :save_ok,
                  [
                    type: :button,
                    part: :arm_err_save_ok,
                    on_click: :save,
                    action_input: %{title: "a valid title"}
                  ],
                  [text("save ok")]
                )
              ])
            else
              button(:edit, [type: :button, part: :arm_err_edit, on_click: :stop_editing], [
                text("closed")
              ])
            end
          ])
        )
      )
    end
  end

  setup do
    MatchIndex.reset()

    on_exit(fn -> Ash.DataLayer.Ets.stop(Page) end)
    :ok
  end

  defp mount_page do
    Process.put(:"$callers", [self()])

    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}},
      private: %{}
    }

    {:ok, socket} =
      AshUi.Phoenix.mount(
        Page,
        %{},
        %{"ash_ui_session_id" => Ash.UUID.generate()},
        socket,
        otp_app: :ash_ui_phoenix
      )

    socket
  end

  defp render_html(socket) do
    rendered = AshUi.Phoenix.render_shell(socket.assigns)
    lv_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {diff, _prints, _components} =
      Phoenix.LiveView.Diff.render(
        lv_socket,
        rendered,
        Phoenix.LiveView.Diff.new_fingerprints(),
        Phoenix.LiveView.Diff.new_components()
      )

    %{}
    |> Phoenix.LiveViewTest.Diff.merge_diff(diff)
    |> Map.delete(:streams)
    |> Phoenix.LiveView.Diff.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp binding_for_part(html, tag, part) do
    chunk =
      html
      |> String.split("<#{tag}")
      |> Enum.find(&String.contains?(&1, ~s(part="#{part}")))

    [_, key] = Regex.run(~r/ash_ui:dispatch:([A-Za-z0-9+\/=._-]+)"/, chunk)
    key
  end

  defp dispatch!(socket, binding_key, extra \\ %{}) do
    {:noreply, socket} =
      AshUi.Phoenix.runtime_handle_event(
        "ash_ui:dispatch",
        Map.merge(%{"binding" => binding_key}, extra),
        socket
      )

    socket
  end

  test "arm-authored bound fields and error reads are registered error slots" do
    table =
      AshUi.Patch.Compiler.cached_table(Page, :view,
        target: AshUi.Phoenix.RenderTarget
      )

    arm_error_slots = Enum.filter(table.error_slots, &(is_binary(&1) and &1 =~ "/t"))

    assert arm_error_slots != [],
           "expected error slots under the then-arm, got: #{inspect(table.error_slots)}"
  end

  test "a failing dispatch paints the arm error surface and success clears it" do
    socket = mount_page()
    html = render_html(socket)
    refute html =~ "title too short"

    bad_key = binding_for_part(html, "button", "arm_err_save_bad")
    socket = dispatch!(socket, bad_key)

    assert socket.assigns[:ash_ui_errors] != []
    error_html = render_html(socket)
    assert error_html =~ "title too short"
    assert socket.assigns.ash_ui_record.title == "untitled"

    ok_key = binding_for_part(error_html, "button", "arm_err_save_ok")
    socket = dispatch!(socket, ok_key)

    assert socket.assigns[:ash_ui_errors] == []
    cleared_html = render_html(socket)
    refute cleared_html =~ "title too short"
    assert socket.assigns.ash_ui_record.title == "a valid title"
  end

  test "a when:-rejected event leaves error state untouched" do
    socket = mount_page()
    html = render_html(socket)

    bad_key = binding_for_part(html, "button", "arm_err_save_bad")
    socket = dispatch!(socket, bad_key)
    assert socket.assigns[:ash_ui_errors] != []

    # The arm input's Enter-gated keydown: a non-Enter key must be a pure
    # no-op — no action run, no error clear, no repaint.
    input_key = binding_for_part(html, "input", "arm_err_input")
    socket = dispatch!(socket, input_key, %{"key" => "a", "title" => "x"})

    assert socket.assigns[:ash_ui_errors] != []
    assert render_html(socket) =~ "title too short"

    # The same binding with Enter and a valid value dispatches and clears.
    socket = dispatch!(socket, input_key, %{"key" => "Enter", "title" => "another valid"})
    assert socket.assigns[:ash_ui_errors] == []
    assert socket.assigns.ash_ui_record.title == "another valid"
  end
end
