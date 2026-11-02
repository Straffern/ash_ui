defmodule AshUi.Phoenix.NilBinaryNotificationTest do
  use ExUnit.Case, async: false

  alias AshUi.Patch.Compiler
  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveViewTest.Diff, as: Client

  defmodule TrackRow do
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:name, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:destroy, create: :*, update: :*])
    end
  end

  defmodule FragmentShell do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:content, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    actions do
      defaults(create: :*)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(box(:shell, [], [content])))
    end
  end

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:track, TrackRow, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :clear_track do
        require_atomic?(false)
        change(set_attribute(:track, nil))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          render(FragmentShell, %{
            content: [
              box(
                :confirm,
                [data: [confirm: "Delete " <> track.name <> "?"]],
                [text("ready")]
              )
            ]
          })
        )
      )
    end
  end

  test "notification reload renders a clean fragment patch when the track row is absent" do
    record =
      Ash.Seed.seed!(Page, %{
        session_id: Ash.UUID.generate(),
        track: %TrackRow{id: "track-1", name: "Track 1"}
      })

    socket = socket(record)
    {full, prints} = render(socket, nil)
    client = Client.merge_diff(%{}, full)
    assert paint(client) =~ ~s(data-confirm="Delete Track 1?")

    record
    |> Ash.Changeset.for_update(:clear_track, %{},
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)

    notification = {:ash_ui_notification, make_ref(), %{resource: TrackRow}}
    send(self(), notification)
    assert_receive ^notification

    assert {:noreply, socket} = AshUi.Phoenix.runtime_handle_info(notification, socket)
    assert socket.assigns.ash_ui_record.track == nil

    {patch, _prints} = render(socket, prints)
    client = Client.merge_diff(client, patch)
    html = paint(client)

    assert patch != %{}
    assert html == static_paint(socket.assigns.ash_ui_record)
    assert html =~ "ready"
    refute html =~ "Delete Track 1?"
  end

  defp socket(record) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        ash_ui_resource: Page,
        ash_ui_view: :view,
        ash_ui_tables: %{
          {Page, :view, AshUi.Phoenix.RenderTarget} =>
            Compiler.table(Page, target: AshUi.Phoenix.RenderTarget)
        },
        ash_ui_session_id: record.session_id,
        ash_ui_actor: nil,
        ash_ui_tenant: nil,
        ash_ui_context: %{},
        ash_ui_record: record,
        ash_ui_changed: :all,
        ash_ui_params: %{}
      }
    }
  end

  defp render(socket, prints) do
    rendered = AshUi.Phoenix.render_shell(socket.assigns)
    lv_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {diff, prints, _components} =
      Diff.render(lv_socket, rendered, prints || Diff.new_fingerprints(), Diff.new_components())

    {diff, prints}
  end

  defp static_paint(record) do
    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(Page),
        record,
        %{},
        target: AshUi.Phoenix.RenderTarget
      )

    {:safe, iodata} =
      AshUi.RenderTarget.Html.render_static(
        tree,
        target: AshUi.Phoenix.RenderTarget
      )

    ~s(<div data-ash-ui-page-root="">#{IO.iodata_to_binary(iodata)}</div>)
  end

  defp paint(client) do
    client |> Map.delete(:streams) |> Diff.to_iodata() |> IO.iodata_to_binary()
  end
end
