defmodule AshUi.Datastar.BridgeTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias AshUi.Datastar.{Bridge, FragmentRender, FragmentRenderTest, RenderTarget, Store}

  defmodule RelatedItem do
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
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:page_key, :string, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, create: [:id, :page_key, :label], update: [:label]])
    end
  end

  defmodule RelationshipPage do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private?(false)
    end

    resource do
      require_primary_key?(false)
    end

    ash_ui do
      stylesheets(["test/support/assets/datastar_test.css"])
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    routes do
      route("/related")
    end

    attributes do
      attribute(:session_id, :uuid, allow_nil?: false, public?: false)
      attribute(:page_key, :string, allow_nil?: false, default: "shared", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :items, RelatedItem do
        source_attribute(:page_key)
        destination_attribute(:page_key)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          list(:items, [], [
            each(items, :related_item, [], [
              item(:related_item, [], [text(related_item.label)])
            ])
          ])
        )
      )
    end

    actions do
      defaults([:read])

      create :mount do
      end
    end
  end

  defmodule RootPage do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(false)
    end

    ash_ui do
      stylesheets(["test/support/assets/datastar_test.css"])
    end

    routes do
      route("/")
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:show?, :boolean, allow_nil?: false, default: true, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
      end

      update :toggle do
        require_atomic?(false)

        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :show?, !changeset.data.show?)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [], [
            button(:toggle, [type: :button, on_click: :toggle], [text("toggle")]),
            if show? do
              paragraph(:shown, [], [text("shown")])
            else
              paragraph(:hidden, [], [text("hidden")])
            end
          ])
        )
      )
    end
  end

  defmodule NavigationPage do
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
      route("/nav")
    end

    attributes do
      attribute(:session_id, :uuid,
        allow_nil?: false,
        primary_key?: true,
        public?: false
      )
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:navigation, [], [
            link(:destination, [to: "/destination?visit=one"], [text("Destination")]),
            link(:new_tab, [to: "/destination?visit=tab", target: "_blank"], [
              text("Destination in new tab")
            ]),
            link(:sign_out, [to: "/sign-out"], [text("Sign out")])
          ])
        )
      )
    end
  end

  defmodule DestinationPage do
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
      route "/destination" do
        query(:visit, :string)
      end
    end

    attributes do
      attribute(:session_id, :uuid,
        allow_nil?: false,
        primary_key?: true,
        public?: false
      )

      attribute(:visit, :string, allow_nil?: false, default: "none", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
        accept([:visit])
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:destination, [], [
            heading(:title, [], [text("Destination")]),
            paragraph(:visit, [], [text(visit)]),
            link(:back, [to: "/nav"], [text("Back")])
          ])
        )
      )
    end
  end

  defmodule SortPage do
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
      route "/" do
        query(:sort_by, :string)
      end
    end

    attributes do
      attribute(:session_id, :uuid,
        allow_nil?: false,
        primary_key?: true,
        public?: false
      )

      attribute(:sort_by, :string, allow_nil?: false, default: "recent", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          form(
            :sort_form,
            [on_change: :change_sort, action_input: %{sort_by: event(:value)}],
            [
              select(:sort_select, [name: "sort_by"], [
                option(:recent, [value: "recent", selected: sort_by == "recent"], [
                  text("recent")
                ]),
                option(:name, [value: "name", selected: sort_by == "name"], [text("name")])
              ])
            ]
          )
        )
      )
    end

    actions do
      defaults([:read])

      create :mount do
        accept([:sort_by])
      end

      update :change_sort do
        accept([:sort_by])
      end
    end
  end

  defp opts(extra \\ []),
    do: Bridge.init(Keyword.merge([resources: [FragmentRenderTest.Page]], extra))

  setup do
    Ash.DataLayer.Ets.stop(FragmentRenderTest.Page)
    Ash.DataLayer.Ets.stop(RelationshipPage)
    Ash.DataLayer.Ets.stop(RelatedItem)
    Ash.DataLayer.Ets.stop(RootPage)
    Ash.DataLayer.Ets.stop(NavigationPage)
    Ash.DataLayer.Ets.stop(DestinationPage)
    Ash.DataLayer.Ets.stop(SortPage)
    AshUi.Notification.MatchIndex.reset()
    :ok
  end

  test "mount serves the full page, vendored client, stable bindings, and session cookie" do
    conn = conn(:get, "/datastar") |> Bridge.call(opts())
    assert conn.status == 200
    assert conn.resp_body =~ "datastar.js"
    assert conn.resp_body =~ "data-on:click=\"@post(&#39;/_ash_ui/dispatch/"
    refute conn.resp_body =~ "data-bind="
    refute conn.resp_body =~ "data-ash-ui-binding"
    assert get_resp_header(conn, "set-cookie") != []

    static = conn(:get, "/_ash_ui/datastar.js") |> Bridge.call(opts())
    assert static.status == 200
    assert byte_size(static.resp_body) > 30_000
    assert static.resp_body =~ "data-ash-ui-updates-stream"
    assert static.resp_body =~ "AshUi"
    assert static.resp_body =~ "ash-ui-client-id"
    assert static.resp_body =~ "__ashUiDatastarClientId"
  end

  test "real signals JSON click and input values mutate current row and stream patches" do
    mount = conn(:get, "/datastar") |> Bridge.call(opts())
    cookie = cookie(mount)
    session_id = cookie_value(cookie)

    click_key = binding_key(mount.resp_body, ~r/<button[^>]*>/, "click")

    clicked =
      conn(
        :post,
        "/_ash_ui/dispatch/" <> URI.encode(click_key),
        Jason.encode!(%{"datastar" => %{}})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", cookie)
      |> Bridge.call(opts())

    assert clicked.status == 200, clicked.resp_body
    assert clicked.resp_body =~ "datastar-patch-elements"
    assert Store.get(session_id).record.show? == false

    mount2 = conn(:get, "/datastar") |> put_req_header("cookie", cookie) |> Bridge.call(opts())
    input_key = binding_key(mount2.resp_body, ~r/<input[^>]*>/, "input")

    input =
      conn(
        :post,
        "/_ash_ui/dispatch/" <> URI.encode(input_key),
        Jason.encode!(%{"datastar" => %{input_key => "Renamed"}})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", cookie)
      |> Bridge.call(opts())

    assert input.status == 200
    assert input.resp_body =~ "Renamed"
    assert Store.get(session_id).record.title == "Renamed"
  end

  test "Ash action errors render through the same field-error projection and clear on success" do
    mount = conn(:get, "/datastar") |> Bridge.call(opts())
    cookie = cookie(mount)
    session_id = cookie_value(cookie)
    input_key = binding_key(mount.resp_body, ~r/<input[^>]*>/, "input")

    failed =
      conn(
        :post,
        "/_ash_ui/dispatch/" <> URI.encode(input_key),
        Jason.encode!(%{"datastar" => %{input_key => "x"}})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", cookie)
      |> Bridge.call(opts())

    assert failed.status == 200
    assert failed.resp_body =~ "data: selector #"
    refute failed.resp_body =~ ~s(<section id=)
    assert failed.resp_body =~ ~s(aria-invalid="true")
    assert failed.resp_body =~ "data-ash-ui-error"
    assert Store.get(session_id).record.title == "Inbox"

    recovered =
      conn(
        :post,
        "/_ash_ui/dispatch/" <> URI.encode(input_key),
        Jason.encode!(%{"datastar" => %{input_key => "Recovered"}})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", cookie)
      |> Bridge.call(opts())

    assert recovered.status == 200
    assert recovered.resp_body =~ "data: selector #"
    refute recovered.resp_body =~ ~s(<section id=)
    refute recovered.resp_body =~ "data-ash-ui-error"
    assert Store.get(session_id).record.title == "Recovered"
  end

  test "unknown and stale binding keys surface as page error state" do
    mount = conn(:get, "/datastar") |> Bridge.call(opts())
    session_id = mount |> cookie() |> cookie_value()

    response =
      conn(:post, "/_ash_ui/dispatch/not-a-live-key", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", cookie(mount))
      |> Bridge.call(opts())

    assert response.status == 200
    assert [_unknown_target | _] = Store.get(session_id).errors
  end

  test "preserves actor, tenant, and full context in session state" do
    actor = %{id: "actor-1"}
    context = %{current_user: actor, tenant: "tenant-1", trace_id: "trace-1"}

    mount = conn(:get, "/datastar") |> Bridge.call(opts(context: context))
    state = mount |> cookie() |> cookie_value() |> Store.get()

    assert state.actor == actor
    assert state.tenant == "tenant-1"
    assert state.context.current_user == actor
    assert state.context.trace_id == "trace-1"
    assert state.context.session_id
  end

  test "session_id extractor shares an externally supplied id across mount and dispatch" do
    session_id = "host-session-#{System.unique_integer([:positive])}"

    mount_config =
      opts(
        resources: [RootPage],
        session_id: {__MODULE__, :session_id_from_assign, [:host_session_id]}
      )

    mount =
      conn(:get, "/")
      |> assign(:host_session_id, session_id)
      |> Bridge.call(mount_config)

    assert mount.status == 200
    assert get_resp_header(mount, "set-cookie") == []
    assert Store.get(session_id).record.show?

    key = binding_key(mount.resp_body, ~r/<button[^>]*>/, "click")

    dispatch_config =
      opts(resources: [RootPage], session_id: &Map.get(&1.assigns, :host_session_id))

    response =
      conn(:post, "/_ash_ui/dispatch/" <> URI.encode(key), "{}")
      |> assign(:host_session_id, session_id)
      |> put_req_header("content-type", "application/json")
      |> Bridge.call(dispatch_config)

    assert response.status == 200
    refute Store.get(session_id).record.show?
  end

  test "two attached clients share one diff stream and survive either disconnect" do
    config =
      opts(
        updates_max_events: 1,
        updates_heartbeat: 5_000
      )

    mount = conn(:get, "/datastar") |> Bridge.call(config)
    cookie = cookie(mount)
    session_id = cookie_value(cookie)

    second_mount =
      conn(:get, "/datastar")
      |> put_req_header("cookie", cookie)
      |> Bridge.call(config)

    assert second_mount.resp_body =~ "Inbox"
    input_key = binding_key(second_mount.resp_body, ~r/<input[^>]*>/, "input")

    client_b = open_updates(config, cookie, "client-b")
    assert_eventually(fn -> Store.client_count(session_id) == 1 end)

    from_a = dispatch_input(config, cookie, input_key, "From A", "client-a")
    assert from_a.resp_body =~ "From A"

    client_b_response = Task.await(client_b, 5_000)
    assert client_b_response.resp_body =~ "Inbox"
    assert client_b_response.resp_body =~ "From A"
    assert Store.get(session_id).record.title == "From A"
    assert_eventually(fn -> Store.client_count(session_id) == 0 end)

    client_a = open_updates(config, cookie, "client-a")
    assert_eventually(fn -> Store.client_count(session_id) == 1 end)

    from_b = dispatch_input(config, cookie, input_key, "From B", "client-b")
    assert from_b.resp_body =~ "From B"

    client_a_response = Task.await(client_a, 5_000)
    assert client_a_response.resp_body =~ "From A"
    assert client_a_response.resp_body =~ "From B"
    assert Store.get(session_id).record.title == "From B"
    assert_eventually(fn -> Store.client_count(session_id) == 0 end)

    persistent_config = opts(updates_heartbeat: 5_000)
    client_a = open_updates(persistent_config, cookie, "client-a")
    client_b = open_updates(persistent_config, cookie, "client-b")
    assert_eventually(fn -> Store.client_count(session_id) == 2 end)

    Task.shutdown(client_a, :brutal_kill)
    assert_eventually(fn -> Store.client_count(session_id) == 1 end)

    after_close =
      dispatch_input(persistent_config, cookie, input_key, "After close", "client-b")

    assert after_close.resp_body =~ "After close"
    assert Store.get(session_id).record.title == "After close"
    assert Process.alive?(client_b.pid)

    Task.shutdown(client_b, :brutal_kill)
    assert_eventually(fn -> Store.client_count(session_id) == 0 end)
    assert Store.notification_info(session_id) == nil
  end

  test "forwarded root route matches path_info and uses the mount prefix for bridge URLs" do
    mount = forward_bridge(conn(:get, "/ds"), resources: [RootPage])

    assert mount.status == 200
    assert mount.resp_body =~ ~s(src="/ds/_ash_ui/datastar.js")
    assert mount.resp_body =~ "@post(&#39;/ds/_ash_ui/dispatch/"
    refute mount.resp_body =~ "@post(&#39;/_ash_ui/dispatch/"

    script =
      forward_bridge(conn(:get, "/ds/_ash_ui/datastar.js"), resources: [RootPage])

    assert script.status == 200

    updates = forward_bridge(conn(:get, "/ds/_ash_ui/updates"), resources: [RootPage])
    assert updates.status == 401

    overridden =
      forward_bridge(conn(:get, "/ds"), resources: [RootPage], base_path: "/edge/ds/")

    assert overridden.resp_body =~ ~s(src="/edge/ds/_ash_ui/datastar.js")
    assert overridden.resp_body =~ "@post(&#39;/edge/ds/_ash_ui/dispatch/"
  end

  test "routed navigation keeps the Datastar document alive and fresh-mounts every destination" do
    bridge_opts = [resources: [NavigationPage, DestinationPage]]
    mount = forward_bridge(conn(:get, "/ds/nav"), bridge_opts)
    cookie = cookie(mount)
    session_id = cookie_value(cookie)

    assert mount.status == 200
    assert get_resp_header(mount, "cache-control") == ["no-store"]
    assert mount.resp_body =~ ~s(href="/ds/destination?visit=one")
    assert mount.resp_body =~ "history.pushState"
    assert mount.resp_body =~ "@get(&quot;/ds/destination?visit=one&quot;"
    assert mount.resp_body =~ "data-on:popstate__window"
    assert length(Regex.scan(~r/data-on:popstate__window/, mount.resp_body)) == 1
    assert mount.resp_body =~ ~r/<body[^>]*data-on:popstate__window=/
    refute mount.resp_body =~ "window.location.assign"

    live_diff = inspect(Store.get(session_id).live.diff)
    assert live_diff =~ "/ds/destination?visit=one"
    refute live_diff =~ RenderTarget.base_path_marker()

    assert mount.resp_body =~ ~s(href="/ds/destination?visit=tab")
    assert mount.resp_body =~ ~s(target="_blank")
    assert mount.resp_body =~ ~s(href="/sign-out")

    first =
      conn(:get, "/ds/destination?visit=one&datastar=%7B%7D")
      |> put_req_header("cookie", cookie)
      |> put_req_header("datastar-request", "true")
      |> forward_bridge(bridge_opts)

    assert first.status == 200
    assert get_resp_header(first, "content-type") == ["text/html; charset=utf-8"]
    assert first.resp_body =~ "Destination"
    assert Store.get(session_id).resource == DestinationPage
    assert Store.get(session_id).record.visit == "one"
    refute Map.has_key?(Store.get(session_id).params, "datastar")
    assert Store.get(session_id).location == "/destination?visit=one"

    second =
      conn(:get, "/ds/destination?visit=two&datastar=%7B%7D")
      |> put_req_header("cookie", cookie)
      |> put_req_header("datastar-request", "true")
      |> forward_bridge(bridge_opts)

    assert second.status == 200
    assert Store.get(session_id).resource == DestinationPage
    assert Store.get(session_id).record.visit == "two"
    assert Store.get(session_id).location == "/destination?visit=two"
  end

  test "a parsed Datastar change payload updates Ash state and patches the scoped URL" do
    bridge_opts = [resources: [SortPage]]
    mount = forward_bridge(conn(:get, "/ds"), bridge_opts)
    cookie = cookie(mount)
    session_id = cookie_value(cookie)

    assert mount.resp_body =~ "&quot;value&quot;: evt.target.value"
    key = binding_key(mount.resp_body, ~r/<form[^>]*>/, "change")

    response =
      conn(
        :post,
        "/ds/_ash_ui/dispatch/" <> URI.encode(key),
        Jason.encode!(%{value: "name"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("cookie", cookie)
      |> then(&%{&1 | body_params: %{"value" => "name"}})
      |> forward_bridge(bridge_opts)

    assert response.status == 200
    assert Store.get(session_id).record.sort_by == "name"
    assert Store.get(session_id).location == "/?sort_by=name"
    assert response.resp_body =~ "/ds/?sort_by=name"
    refute response.resp_body =~ "window.location.assign"
  end

  test "root mount output is exactly the page shell, one history handler, and fragment" do
    mount = conn(:get, "/") |> Bridge.call(opts(resources: [RootPage]))
    state = mount |> cookie() |> cookie_value() |> Store.get()

    fragment =
      FragmentRender.full_render(state.record, state.table,
        actor: state.actor,
        tenant: state.tenant,
        context: state.context,
        session_id: state.context.session_id,
        params: state.params
      )

    popstate =
      AshUi.RenderTarget.Html.attributes_iodata(%{
        "data-on:popstate__window" => RenderTarget.popstate_expression()
      })
      |> IO.iodata_to_binary()

    expected =
      "<!doctype html><html><head><meta charset=\"utf-8\"><script type=\"module\" src=\"/_ash_ui/datastar.js\"></script></head><body#{popstate}>#{fragment}</body></html>"

    assert mount.resp_body == expected
  end

  test "relationship notifications reload and patch the page relationship" do
    item =
      RelatedItem
      |> Ash.Changeset.for_create(
        :create,
        %{id: "item-1", page_key: "shared", label: "Before"},
        domain: AshUi.AshDomainFallback
      )
      |> Ash.create!(domain: AshUi.AshDomainFallback)

    config =
      opts(
        resources: [RelationshipPage],
        updates_max_events: 1,
        updates_heartbeat: 5_000
      )

    mount = conn(:get, "/related") |> Bridge.call(config)
    cookie = cookie(mount)
    session_id = cookie_value(cookie)
    assert Store.get(session_id).record.items |> Enum.map(& &1.label) == ["Before"]

    updates =
      Task.async(fn ->
        conn(:get, "/_ash_ui/updates")
        |> put_req_header("cookie", cookie)
        |> Bridge.call(config)
      end)

    registered? =
      Enum.reduce_while(1..100, false, fn _, _ ->
        if AshUi.Notification.MatchIndex.subs_for(RelatedItem) == [] do
          receive do
          after
            10 -> {:cont, false}
          end
        else
          {:halt, true}
        end
      end)

    assert registered?

    item
    |> Ash.Changeset.for_update(:update, %{label: "After"},
      domain: AshUi.AshDomainFallback
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)

    response = Task.await(updates, 5_000)
    assert response.status == 200
    assert Store.get(session_id).record.items |> Enum.map(& &1.label) == ["After"]
  end

  test "one notification mailbox burst produces one page reload" do
    RelatedItem
    |> Ash.Changeset.for_create(
      :create,
      %{id: "item-1", page_key: "shared", label: "Before"},
      domain: AshUi.AshDomainFallback
    )
    |> Ash.create!(domain: AshUi.AshDomainFallback)

    config =
      opts(
        resources: [RelationshipPage],
        updates_max_events: 2,
        updates_heartbeat: 5_000
      )

    mount = conn(:get, "/related") |> Bridge.call(config)
    cookie = cookie(mount)
    session_id = cookie_value(cookie)

    updates =
      Task.async(fn ->
        conn(:get, "/_ash_ui/updates")
        |> put_req_header("cookie", cookie)
        |> Bridge.call(config)
      end)

    {ref, subscription} =
      Enum.reduce_while(1..100, nil, fn _, _ ->
        case List.first(AshUi.Notification.MatchIndex.subs_for(RelatedItem)) do
          nil ->
            receive do
            after
              10 -> {:cont, nil}
            end

          subscription ->
            {:halt, subscription}
        end
      end) || flunk("updates subscription was not registered")

    # Deliver the first hint early while a dispatch-cycle transaction is
    # still active, then deliver the rest after the old 1ms coalescing window.
    # The update loop must cross the session owner after the transaction and
    # drain all 100 hints as one reload, independent of scheduler timing.
    Store.transaction(session_id, fn ->
      Task.async(fn ->
        send(subscription.pid, {:ash_ui_notification, ref, %{resource: RelatedItem}})

        receive do
        after
          10 -> :ok
        end

        Enum.each(2..100, fn _ ->
          send(subscription.pid, {:ash_ui_notification, ref, %{resource: RelatedItem}})
        end)
      end)
      |> Task.await()
    end)

    receive do
    after
      50 -> :ok
    end

    assert Task.yield(updates, 0) == nil

    assert Store.client_count(session_id) == 1
    assert AshUi.Notification.MatchIndex.subscription(ref)

    send(subscription.pid, {:ash_ui_notification, ref, %{resource: RelatedItem}})
    assert Task.await(updates, 5_000).status == 200
  end

  defp cookie(conn),
    do: conn |> get_resp_header("set-cookie") |> hd() |> String.split(";", parts: 2) |> hd()

  defp cookie_value(cookie), do: cookie |> String.split("=", parts: 2) |> List.last()

  defp binding_key(html, element_regex, event) do
    [element] = Regex.run(element_regex, html)

    [_, encoded_key] =
      Regex.run(
        ~r/data-on:#{Regex.escape(event)}="[^"]*?\/_ash_ui\/dispatch\/([^&'"),\s]+)/,
        element
      )

    URI.decode(encoded_key)
  end

  defp open_updates(config, cookie, client_id) do
    Task.async(fn ->
      conn(:get, "/_ash_ui/updates")
      |> put_req_header("cookie", cookie)
      |> put_req_header("ash-ui-client-id", client_id)
      |> Bridge.call(config)
    end)
  end

  defp dispatch_input(config, cookie, key, value, client_id) do
    conn(
      :post,
      "/_ash_ui/dispatch/" <> URI.encode(key),
      Jason.encode!(%{"datastar" => %{key => value}})
    )
    |> put_req_header("content-type", "application/json")
    |> put_req_header("cookie", cookie)
    |> put_req_header("ash-ui-client-id", client_id)
    |> Bridge.call(config)
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        10 -> assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  def session_id_from_assign(conn, key), do: Map.get(conn.assigns, key)

  defp forward_bridge(%Plug.Conn{path_info: ["ds" | rest]} = conn, opts),
    do: Plug.forward(conn, rest, Bridge, Bridge.init(opts))
end
