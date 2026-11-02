defmodule AshUi.Phoenix.LocationProjectionTest do
  @moduledoc """
  DESIGN §8: the browser location is a projection of route-declared state,
  as the DOM is a projection of view state.

    1. Route declarations are two-way: a dispatch that changes a declared
       query attribute patches the URL to the template filled from the
       CURRENT row; unrelated changes leave the location alone.
    2. Page handoff is the same projection: a declared `location:`
       expression evaluating to a URL outside the page's template
       navigates; nil means the page's own template.
    3. Reconciliation is idempotent — a location already equal to the
       projection produces no redirect.
  """
  use ExUnit.Case, async: false

  alias AshUi.Phoenix, as: Bridge

  defmodule CatalogPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    ash_ui do
      stylesheets(["test/support/assets/routed_fixtures.css"])
    end

    routes do
      route "/catalog" do
        query(:q, :string)
        query(:sort_by, :string)
      end
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:q, :string, public?: true)
      attribute(:sort_by, :string, public?: true)
      attribute(:unrelated, :string, allow_nil?: false, default: "x", public?: true)
      attribute(:folds, {:array, :string}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(box(:root, [], [text("catalog")])))
    end
  end

  defmodule FormPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    ash_ui do
      stylesheets(["test/support/assets/routed_fixtures.css"])
    end

    routes do
      route("/artists/new",
        location:
          expr(
            if not is_nil(saved_artist_id) do
              "/artists/" <> saved_artist_id
            end
          )
      )
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:saved_artist_id, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(box(:root, [], [text("form")])))
    end
  end

  defmodule MountOncePage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    ash_ui do
      stylesheets(["test/support/assets/routed_fixtures.css"])
    end

    routes do
      route "/mount-once" do
        query(:q, :string)
      end
    end

    attributes do
      attribute(:session_id, :uuid, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:q, :string, public?: true)
      attribute(:mount_token, :uuid, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
        argument(:q, :string)
        change(set_attribute(:q, arg(:q)))

        change(fn changeset, _context ->
          Ash.Changeset.force_change_attribute(changeset, :mount_token, Ash.UUID.generate())
        end)
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text(q)))
    end
  end

  defmodule ActionEffectPage do
    @moduledoc false

    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    ash_ui do
      stylesheets(["test/support/assets/routed_fixtures.css"])
    end

    routes do
      route "/action-effect" do
        query(:anchor, :string)
      end
    end

    attributes do
      attribute(:session_id, :uuid, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:anchor, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
        argument(:anchor, :string)
        change(set_attribute(:anchor, arg(:anchor)))

        change(
          scroll_into_view(
            part: :document_match,
            block: :center,
            when_arguments: [:anchor]
          )
        )
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text(anchor)))
    end
  end

  defp socket(location) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, ash_ui_location: location}
    }
  end

  defp seed(resource, attrs) do
    Ash.Seed.seed!(resource, Map.put(attrs, :session_id, Ash.UUID.generate()))
  end

  test "a declared query attribute change patches the URL from the current row" do
    refute Ash.Resource.Info.attribute(CatalogPage, nil)
    refute Enum.any?(Ash.Resource.Info.action(CatalogPage, :create).arguments, &is_nil(&1.name))

    record = seed(CatalogPage, %{q: "beatles", sort_by: "-updated_at"})

    assert %{redirected: {:live, :patch, %{to: to}}} =
             Bridge.reconcile_location(socket("/catalog"), record)

    assert URI.decode_query(URI.parse(to).query) == %{
             "q" => "beatles",
             "sort_by" => "-updated_at"
           }

    assert URI.parse(to).path == "/catalog"
  end

  test "mount ignores undeclared query params that collide with public attributes" do
    session_id = Ash.UUID.generate()
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    assert {:ok, socket} =
             Bridge.mount(
               CatalogPage,
               %{"q" => "beatles", "folds" => "not-an-array"},
               %{"ash_ui_session_id" => session_id},
               socket
             )

    assert socket.assigns.ash_ui_record.q == "beatles"
    assert socket.assigns.ash_ui_record.folds == []
  end

  test "initial handle_params reuses the row mounted from the same params" do
    session_id = Ash.UUID.generate()
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    params = %{"q" => "first"}

    assert {:ok, mounted} =
             Bridge.mount(
               MountOncePage,
               params,
               %{"ash_ui_session_id" => session_id},
               socket
             )

    mount_token = mounted.assigns.ash_ui_record.mount_token

    assert {:noreply, unchanged} =
             Bridge.runtime_handle_params(params, "/mount-once?q=first", mounted)

    assert unchanged.assigns.ash_ui_record.mount_token == mount_token
    assert unchanged.assigns.ash_ui_location == "/mount-once?q=first"

    assert {:noreply, changed} =
             Bridge.runtime_handle_params(
               %{"q" => "second"},
               "/mount-once?q=second",
               unchanged
             )

    assert changed.assigns.ash_ui_record.q == "second"
    refute changed.assigns.ash_ui_record.mount_token == mount_token
  end

  test "static/live handoff pushes a mount action effect once and rerender does not replay it" do
    session_id = Ash.UUID.generate()
    params = %{"anchor" => "quoted text"}
    static_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    assert {:ok, static_mounted} =
             Bridge.mount(
               ActionEffectPage,
               params,
               %{"ash_ui_session_id" => session_id},
               static_socket
             )

    assert Phoenix.LiveView.Utils.get_push_events(static_mounted) == []

    connected_socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{live_temp: %{}},
      transport_pid: self()
    }

    Process.put(:"$callers", [self()])

    assert {:ok, live_mounted} =
             Bridge.mount(
               ActionEffectPage,
               params,
               %{"ash_ui_session_id" => session_id},
               connected_socket
             )

    assert Phoenix.LiveView.Utils.get_push_events(live_mounted) == [
             [
               "ash_ui:scroll-into-view",
               %{
                 part: "document_match",
                 options: %{behavior: :auto, block: :center, inline: :nearest}
               }
             ]
           ]

    assert {:noreply, rerendered} =
             Bridge.runtime_handle_params(
               params,
               "/action-effect?anchor=quoted+text",
               live_mounted
             )

    assert Phoenix.LiveView.Utils.get_push_events(rerendered) ==
             Phoenix.LiveView.Utils.get_push_events(live_mounted)
  end

  test "reconciliation is idempotent: matching location produces no redirect" do
    record = seed(CatalogPage, %{q: "beatles", sort_by: nil})
    socket = Bridge.reconcile_location(socket("/catalog?q=beatles"), record)
    assert socket.redirected == nil
  end

  test "host-preserved query params survive location reconciliation" do
    record = seed(CatalogPage, %{q: "beatles", sort_by: nil})

    socket =
      "/catalog?gl_session_id=session-one&host_surface=sidebar-explorer&q=beatles&ui_session_id=ui-one"
      |> socket()
      |> Phoenix.Component.assign(:ash_ui_context, %{
        shared: %{
          ash_ui_preserved_query_params: %{
            "gl_session_id" => "session-one",
            "host_surface" => "sidebar-explorer",
            "ui_session_id" => "ui-one"
          }
        }
      })
      |> Bridge.reconcile_location(record)

    assert socket.redirected == nil
  end

  test "nil query attributes drop out of the projection" do
    record = seed(CatalogPage, %{q: nil, sort_by: nil})

    assert %{redirected: {:live, :patch, %{to: "/catalog"}}} =
             Bridge.reconcile_location(socket("/catalog?q=old"), record)
  end

  test "a nil location expression means the page's own template" do
    record = seed(FormPage, %{saved_artist_id: nil})
    socket = Bridge.reconcile_location(socket("/artists/new"), record)
    assert socket.redirected == nil
  end

  test "a location expression projecting outside the template navigates" do
    record = seed(FormPage, %{saved_artist_id: "abc-123"})

    assert %{redirected: {:live, :redirect, %{to: "/artists/abc-123"}}} =
             Bridge.reconcile_location(socket("/artists/new"), record)
  end

  test "no reconciliation without a known current location" do
    record = seed(CatalogPage, %{q: "x", sort_by: nil})
    socket = Bridge.reconcile_location(socket(nil), record)
    assert socket.redirected == nil
  end
end
