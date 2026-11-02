defmodule AshUi.Phoenix.DomainRowsTest do
  use ExUnit.Case, async: false

  alias AshUi.EventBinding
  alias AshUi.Patch.Compiler

  defmodule Artist do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false,
      authorizers: [Ash.Policy.Authorizer],
      notifiers: [AshUi.Notifier]

    ets do
      private?(true)
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      attribute(:id, :string, allow_nil?: false, primary_key?: true, public?: true)
      attribute(:owner_id, :string, allow_nil?: false, public?: true)
      attribute(:visible?, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:followed?, :boolean, allow_nil?: false, default: false, public?: true)
      attribute(:rank, :integer, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*])

      update :follow do
        require_atomic?(false)
        argument(:rank, :integer, allow_nil?: false)
        change(set_attribute(:followed?, true))
        change(set_attribute(:rank, arg(:rank)))
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource Artist do
        define(:follow_artist,
          action: :follow,
          get_by: [:id, :owner_id, :visible?],
          args: [:rank]
        )

        define(:destroy_artist,
          action: :destroy,
          get_by: [:id, :owner_id, :visible?]
        )
      end
    end
  end

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private?(true)
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:owner_id, :string, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :artists, Artist do
        source_attribute(:owner_id)
        destination_attribute(:owner_id)
        filter(expr(visible? == true))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          each(artists, :artist, [key: artist.id], [
            button(
              :follow,
              [
                on_click: :follow_artist,
                action_input: %{artist_id: artist.id, rank: event(:button)}
              ],
              [text(artist.id)]
            ),
            button(
              :destroy,
              [on_click: :destroy_artist, action_input: %{artist_id: artist.id}],
              [text("destroy")]
            )
          ])
        )
      )
    end

    actions do
      defaults([:read])

      update :follow_artist do
        require_atomic?(false)

        argument(:artist_id, :string, allow_nil?: false)
        argument(:rank, :integer, allow_nil?: false)

        change(fn changeset, context ->
          case Domain.follow_artist(
                 changeset.arguments.artist_id,
                 changeset.data.owner_id,
                 true,
                 changeset.arguments.rank,
                 scope: context
               ) do
            {:ok, _artist} -> changeset
            {:error, error} -> Ash.Changeset.add_error(changeset, error)
          end
        end)
      end

      update :destroy_artist do
        require_atomic?(false)

        argument(:artist_id, :string, allow_nil?: false)

        change(fn changeset, context ->
          case Domain.destroy_artist(
                 changeset.arguments.artist_id,
                 changeset.data.owner_id,
                 true,
                 scope: context
               ) do
            :ok -> changeset
            {:ok, _artist} -> changeset
            {:error, error} -> Ash.Changeset.add_error(changeset, error)
          end
        end)
      end
    end
  end

  setup do
    Ash.DataLayer.Ets.stop(Page)
    Ash.DataLayer.Ets.stop(Artist)
    AshUi.Notification.MatchIndex.reset()
    :ok
  end

  test "Phoenix dispatch updates a relationship row without replacing the page record" do
    {page, artist} = seed("update")
    socket = socket(page)
    key = binding_key(socket, artist.id, :follow_artist)

    assert {:noreply, socket} =
             AshUi.Phoenix.runtime_handle_event(
               "ash_ui:dispatch:" <> key,
               %{"button" => "9"},
               socket
             )

    assert %Page{} = socket.assigns.ash_ui_record
    assert [%Artist{followed?: true, rank: 9}] = socket.assigns.ash_ui_record.artists
    assert socket.assigns[:ash_ui_errors] in [nil, []]
  end

  test "Phoenix dispatch destroys a relationship row and refreshes the existing page" do
    {page, artist} = seed("destroy")
    socket = socket(page)
    key = binding_key(socket, artist.id, :destroy_artist)

    assert {:noreply, socket} =
             AshUi.Phoenix.runtime_handle_event(
               "ash_ui:dispatch:" <> key,
               %{},
               socket
             )

    assert %Page{} = socket.assigns.ash_ui_record
    assert socket.assigns.ash_ui_record.artists == []
    assert socket.assigns[:ash_ui_errors] in [nil, []]
  end

  test "Phoenix surfaces a stale relationship key as ordinary page error state" do
    {page, _visible} = seed("scoped")
    hidden = create_artist!(page.owner_id, "hidden", false)
    stale_projection = %{page | artists: [hidden]}
    socket = socket(stale_projection)
    key = binding_key(socket, hidden.id, :follow_artist)

    assert {:noreply, socket} =
             AshUi.Phoenix.runtime_handle_event(
               "ash_ui:dispatch:" <> key,
               %{"button" => "1"},
               socket
             )

    assert %Page{} = socket.assigns.ash_ui_record
    assert [_error | _] = socket.assigns.ash_ui_errors

    assert %Artist{followed?: false, rank: nil} =
             Ash.get!(Artist, hidden.id, domain: AshUi.AshDomainFallback)
  end

  defp seed(id) do
    owner_id = Ash.UUID.generate()
    page = Ash.Seed.seed!(Page, %{session_id: Ash.UUID.generate(), owner_id: owner_id})
    artist = create_artist!(owner_id, id, true)

    page =
      Ash.load!(page, :artists,
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )

    {page, artist}
  end

  defp create_artist!(owner_id, id, visible?) do
    Artist
    |> Ash.Changeset.for_create(
      :create,
      %{id: id, owner_id: owner_id, visible?: visible?},
      domain: AshUi.AshDomainFallback
    )
    |> Ash.create!()
  end

  defp socket(record) do
    table = Compiler.table(Page, target: AshUi.Phoenix.RenderTarget)
    subscription_ref = {__MODULE__, self(), record.session_id, :artists}

    :ok =
      AshUi.Notification.MatchIndex.register(subscription_ref, %{
        pid: self(),
        resource: Artist,
        attrs: [owner_id: record.owner_id],
        reload_scope: [:artists],
        tenant: nil
      })

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        ash_ui_resource: Page,
        ash_ui_view: :view,
        ash_ui_tables: %{{Page, :view, AshUi.Phoenix.RenderTarget} => table},
        ash_ui_session_id: record.session_id,
        ash_ui_actor: nil,
        ash_ui_tenant: nil,
        ash_ui_context: %{},
        ash_ui_record: record,
        ash_ui_changed: :all,
        ash_ui_params: %{},
        ash_ui_notification_refs: MapSet.new([subscription_ref])
      }
    }
  end

  defp binding_key(socket, entry_key, action) do
    table =
      Map.fetch!(
        socket.assigns.ash_ui_tables,
        {Page, :view, AshUi.Phoenix.RenderTarget}
      )

    {addr, event} =
      Enum.find_value(table.event_elements, fn {addr, entry} ->
        Enum.find_value(List.wrap(entry.node.events), fn binding ->
          if binding.ui_event == action, do: {addr, binding.dom_event}
        end)
      end)

    Enum.join(
      [EventBinding.key_component(entry_key), Compiler.addr_component(addr), event],
      "."
    )
  end
end
