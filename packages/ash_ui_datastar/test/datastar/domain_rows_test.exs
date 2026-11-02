defmodule AshUi.Datastar.DomainRowsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AshUi.Datastar.{Bridge, Store}
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
      private?(false)
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
      private?(false)
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    ash_ui do
      stylesheets(["test/support/assets/datastar_test.css"])
    end

    routes do
      route("/domain-rows")
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:owner_id, :string, allow_nil?: false, default: "shared", public?: true)
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

      create :mount do
      end

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

  test "Datastar dispatch updates a relationship row and retains the page record" do
    artist = create_artist!("update", true)
    {config, cookie, session_id, state} = mount()
    key = binding_key(state.table, artist.id, :follow_artist)

    response = dispatch(config, cookie, key, %{"button" => "11"})

    assert response.status == 200, response.resp_body
    assert %Page{} = Store.get(session_id).record
    assert [%Artist{followed?: true, rank: 11}] = Store.get(session_id).record.artists
    assert Store.get(session_id).errors == []
  end

  test "Datastar dispatch destroys a relationship row and refreshes the page relationship" do
    artist = create_artist!("destroy", true)
    {config, cookie, session_id, state} = mount()
    key = binding_key(state.table, artist.id, :destroy_artist)

    response = dispatch(config, cookie, key, %{})

    assert response.status == 200, response.resp_body
    assert %Page{} = Store.get(session_id).record
    assert Store.get(session_id).record.artists == []
    assert Store.get(session_id).errors == []
  end

  test "Datastar turns a stale relationship key into ordinary page error state" do
    hidden = create_artist!("hidden", false)
    {config, cookie, session_id, state} = mount()

    :ok = Store.put(session_id, %{state | record: %{state.record | artists: [hidden]}})
    key = binding_key(state.table, hidden.id, :follow_artist)

    response = dispatch(config, cookie, key, %{"button" => "1"})

    assert response.status == 200, response.resp_body
    assert %Page{} = Store.get(session_id).record
    assert [_error | _] = Store.get(session_id).errors
    refute response.resp_body =~ "forbidden"

    assert %Artist{followed?: false, rank: nil} =
             Ash.get!(Artist, hidden.id, domain: AshUi.AshDomainFallback)
  end

  defp mount do
    config = Bridge.init(resources: [Page])
    response = conn(:get, "/domain-rows") |> Bridge.call(config)

    cookie =
      response |> get_resp_header("set-cookie") |> hd() |> String.split(";", parts: 2) |> hd()

    session_id = cookie |> String.split("=", parts: 2) |> List.last()
    {config, cookie, session_id, Store.get(session_id)}
  end

  defp dispatch(config, cookie, key, signals) do
    conn(
      :post,
      "/_ash_ui/dispatch/" <> URI.encode(key),
      Jason.encode!(signals)
    )
    |> put_req_header("content-type", "application/json")
    |> put_req_header("cookie", cookie)
    |> Bridge.call(config)
  end

  defp create_artist!(id, visible?) do
    Artist
    |> Ash.Changeset.for_create(
      :create,
      %{id: id, owner_id: "shared", visible?: visible?},
      domain: AshUi.AshDomainFallback
    )
    |> Ash.create!()
  end

  defp binding_key(table, entry_key, action) do
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
