defmodule AshUi.RouteParamExprTest do
  use ExUnit.Case, async: false

  defmodule RouteParamResult do
    use Ash.Resource,
      domain: AshUi.RouteParamExprTest.RouteParamDomain,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:query, :string, public?: true)
      attribute(:query_defaulted, :string, public?: true)
      attribute(:sort_by, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule RouteParamDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(RouteParamResult)
    end
  end

  defmodule RouteParamPage do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

    ets do
      private?(true)
    end

    ash_ui do
    end

    import AshUi.ViewConstructor

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:q, :string, public?: true)
      attribute(:sort_state, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:artists, RouteParamResult) do
        no_attributes?(true)
        read_action(:read)
        filter(expr(query == parent(q) and sort_by == parent(sort_state)))
      end
    end

    route do
      query(:q, default: "", state: :q)
      query(:sort_by, default: "-updated_at", state: :sort_state)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:stack, [], [
            text(q),
            text(
              if is_nil(q) do
                ""
              else
                q
              end
            ),
            text(sort_state)
          ])
        )
      )
    end
  end

  defmodule RouteStatePage do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

    ets do
      private?(true)
    end

    ash_ui do
    end

    import AshUi.ViewConstructor

    route do
      query(:folder, :string, default: "inbox", state: :active_folder)
      query(:mailbox_id, :string, state: :active_mailbox_id)
      query(:panel, :string, state: :active_panel)
      param(:count, :integer, state: :active_count)
      param(:mode, :string, default: "compact", state: :active_mode)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:active_folder, :string, public?: true)
      attribute(:active_mailbox_id, :string, public?: true)
      attribute(:active_panel, :string, public?: true)
      attribute(:active_count, :integer, public?: true)
      attribute(:active_mode, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:stack, [], [
            text(active_folder),
            text(active_mailbox_id || ""),
            text(active_panel || ""),
            text(to_string(active_count)),
            text(to_string(active_mode))
          ])
        )
      )
    end
  end

  test "route-bound mount arguments feed relationship reads and views" do
    Ash.DataLayer.Ets.stop(RouteParamResult)

    Ash.create!(RouteParamResult, %{query: "Ada", query_defaulted: "Ada", sort_by: "name"},
      domain: RouteParamDomain
    )

    # route params bind through the mount action arguments by state name
    page =
      RouteParamPage
      |> Ash.Changeset.for_create(:mount, %{q: "Ada", sort_state: "name"},
        domain: AshUi.AshDomainFallback,
        authorize?: false,
        context: %{session_id: Ash.UUID.generate()}
      )
      |> Ash.create!()

    assert page.q == "Ada"
    assert page.sort_state == "name"

    loaded =
      Ash.load!(page, :artists, domain: AshUi.AshDomainFallback, authorize?: false)

    assert [%RouteParamResult{query: "Ada", query_defaulted: "Ada", sort_by: "name"}] =
             loaded.artists

    assert {:ok,
            %{
              kind: :element,
              tag: :div,
              children: [%{content: "Ada"}, %{content: "Ada"}, %{content: "name"}]
            }} =
             AshUi.Runtime.Rendering.render_view(
               AshUi.Runtime.ResourceInfo.compiled_resource(RouteParamPage),
               page,
               %{}
             )
  end

  test "route_state mirrors route-bound mount arguments directly into resource state" do
    page =
      RouteStatePage
      |> Ash.Changeset.for_create(
        :mount,
        %{
          active_folder: "archive",
          active_mailbox_id: "mbx_123",
          active_panel: "compose",
          active_count: "7",
          active_mode: "expanded"
        },
        domain: AshUi.AshDomainFallback,
        authorize?: false,
        context: %{session_id: Ash.UUID.generate()}
      )
      |> Ash.create!()

    assert page.active_folder == "archive"
    assert page.active_mailbox_id == "mbx_123"
    assert page.active_panel == "compose"
    assert page.active_count == 7
    assert page.active_mode == "expanded"

    assert {:ok,
            %{
              kind: :element,
              tag: :div,
              children: [
                %{content: "archive"},
                %{content: "mbx_123"},
                %{content: "compose"},
                %{content: "7"},
                %{content: "expanded"}
              ]
            }} =
             AshUi.Runtime.Rendering.render_view(
               AshUi.Runtime.ResourceInfo.compiled_resource(RouteStatePage),
               page,
               %{}
             )
  end
end
