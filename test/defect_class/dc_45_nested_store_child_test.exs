defmodule AshUi.DefectClass.DC45NestedStoreChildTest do
  @moduledoc """
  DC-45: EVERY rendered binding key resolves — the one-key-language
  invariant holds through a store-backed session child nested inside an
  embedded child (the app-shell shape: page → embedded Shell(assigns) →
  store-backed Widget resolved by session identity), including keys
  inside the widget's branch arms.
  """
  use ExUnit.Case, async: false

  alias AshUi.Patch.Bindings
  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Runtime

  defmodule Widget do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :uuid,
        allow_nil?: false,
        primary_key?: true,
        public?: false
      )

      attribute(:signed_in?, :boolean, allow_nil?: false, default: false, public?: true)
      attribute(:open?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, create: :*])

      create :mount do
      end

      update :toggle do
        require_atomic?(false)

        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :open?, not changeset.data.open?)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:widget_root, [state: [open: open?]], [
            if signed_in? do
              box(:avatar, [tabindex: 0, role: "button", on_click: :toggle], [text("avatar")])
            else
              text("anon")
            end
          ])
        )
      )
    end
  end

  defmodule Shell do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:signed_in?, :boolean, allow_nil?: false, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:shell_root, [], [
            render(AshUi.DefectClass.DC45NestedStoreChildTest.Widget, %{
              signed_in?: signed_in?
            }),
            box(:shell_body, [], [text("body")])
          ])
        )
      )
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
      attribute(:session_id, :uuid, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:signed_in?, :boolean, allow_nil?: false, default: true, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:widgets, Widget,
        source_attribute: :session_id,
        destination_attribute: :session_id,
        public?: true
      )
    end

    actions do
      defaults([:read, create: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          render(AshUi.DefectClass.DC45NestedStoreChildTest.Shell, %{
            signed_in?: signed_in?
          })
        )
      )
    end
  end

  test "every rendered binding key resolves against the page row" do
    session_id = Ash.UUID.generate()
    page = Ash.Seed.seed!(Page, %{session_id: session_id, signed_in?: true})
    Ash.Seed.seed!(Widget, %{session_id: session_id, signed_in?: true, open?: true})

    assert AshUi.view_load(Page) == [:widgets]

    page =
      Ash.load!(page, AshUi.view_load(Page),
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )

    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(Page),
        page,
        %{},
        session_id: page.session_id
      )

    {:safe, iodata} =
      AshUi.RenderTarget.Html.render_static(tree,
        target: AshUi.RenderTarget.Static
      )

    html = IO.iodata_to_binary(iodata)

    keys =
      ~r/data-ash-ui-binding="([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert keys != [], "the widget avatar must render a binding: #{html}"

    for key <- keys do
      assert {:ok, binding, target} =
               Bindings.resolve(page, key, %{}, session_id: page.session_id),
             "rendered key #{inspect(key)} must resolve (one key language)"

      assert binding.ui_event == :toggle
      assert {:row, %Widget{open?: true}} = target
    end
  end

  test "a nested store row change invalidates its relationship-backed child boundary" do
    session_id = Ash.UUID.generate()
    page = Ash.Seed.seed!(Page, %{session_id: session_id, signed_in?: true})
    widget = Ash.Seed.seed!(Widget, %{session_id: session_id, signed_in?: true, open?: false})

    page =
      Ash.load!(page, AshUi.view_load(Page),
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )

    widget
    |> Ash.Changeset.for_update(:toggle, %{},
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)

    assert {:ok, reloaded_page} =
             AshUi.reload(page,
               domain: AshUi.AshDomainFallback,
               authorize?: false
             )

    updated_page =
      Ash.load!(reloaded_page, AshUi.view_load(Page),
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )

    table = Compiler.table(Page)

    assert Map.has_key?(table.propagation, :widgets)
    assert Runtime.changed_addresses(table, page, updated_page) == MapSet.new(["v"])
  end
end
