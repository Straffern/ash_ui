defmodule AshUi.Phoenix.RouterTest do
  use ExUnit.Case, async: true

  defmodule StaticResource do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      validate_domain_inclusion?: false

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end

    def __ash_ui_route__, do: {"/things/new", []}
  end

  defmodule ParamResource do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      validate_domain_inclusion?: false

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end

    def __ash_ui_route__, do: {"/things/:thing_id", [:tab]}
  end

  defmodule UnroutedResource do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      validate_domain_inclusion?: false

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(StaticResource)
      resource(ParamResource)
      resource(UnroutedResource)
    end
  end

  defmodule Router do
    use AshUi.Phoenix.Router, presets: []

    ash_ui_routes(domains: [Domain])
  end

  test "discovers routed resources from domains and mounts the resource" do
    routes = Phoenix.Router.routes(Router)

    assert Enum.map(routes, & &1.path) == ["/things/new", "/things/:thing_id"]

    assert Enum.map(routes, fn route ->
             route.metadata.ash_ui_route_metadata.resource
           end) == [StaticResource, ParamResource]
  end

  test "carries only resource route data" do
    metadata =
      Router
      |> Phoenix.Router.routes()
      |> Enum.find(&(&1.path == "/things/:thing_id"))
      |> then(& &1.metadata.ash_ui_route_metadata)

    assert %AshUi.Phoenix.RouteMetadata{
             resource: ParamResource,
             path: "/things/:thing_id",
             query: [:tab]
           } = metadata

    refute Map.has_key?(metadata, :app)
    refute Map.has_key?(metadata, :screen)
    refute function_exported?(AshUi.Phoenix.Router, :ash_ui_app, 2)
  end
end
