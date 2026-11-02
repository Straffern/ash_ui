defmodule AshUi.DefectClass.DC34StoreRenderIdentityTest do
  use ExUnit.Case, async: false

  defmodule Panel do
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
      attribute(:panel_id, :string, allow_nil?: false, primary_key?: true, public?: true)
      attribute(:open?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id, :panel_id],
        pre_check_with: AshUi.AshDomainFallback
      )
    end

    actions do
      create :mount do
        accept([:panel_id])
      end

      update(:toggle) do
        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :open?, !changeset.data.open?)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(text(panel_id <> ":" <> to_string(open?)))
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
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:requested_panel_id, :string, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:panels, Panel,
        source_attribute: :session_id,
        destination_attribute: :session_id,
        public?: true
      )
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(render(Panel, %{panel_id: requested_panel_id}))
      )
    end
  end

  test "loaded relationship row renders its stored state" do
    page = seed("stored")
    stored = %Panel{session_id: page.session_id, panel_id: "stored", open?: true}
    page = Map.put(page, :panels, [stored])

    assert render_text(page) =~ "stored:true"
  end

  test "absent relationship subject renders input with defaults" do
    page = seed("absent")
    page = Map.put(page, :panels, [])

    assert render_text(page) =~ "absent:false"
  end

  test "a lazily mounted and updated row is selected on re-render" do
    page = seed("lazy")

    # store-backed rows are ordinary Ash rows: lazy mount is the row's
    # session-scoped mount upsert, the event is an ordinary update action
    panel =
      Panel
      |> Ash.Changeset.for_create(:mount, %{panel_id: "lazy"},
        domain: AshUi.AshDomainFallback,
        authorize?: false,
        context: %{session_id: page.session_id}
      )
      |> Ash.create!()

    toggled =
      panel
      |> Ash.Changeset.for_update(:toggle, %{},
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )
      |> Ash.update!(domain: AshUi.AshDomainFallback)

    page = Map.put(page, :panels, [toggled])
    assert render_text(page) =~ "lazy:true"
  end

  test "a sparse prototype mounts with its declared inputs before its first update" do
    page = seed("prototype")

    assert {:ok, prototype} =
             AshUi.build_child_record(
               Panel,
               %{panel_id: "prototype"},
               parent_record: page,
               session_id: page.session_id
             )

    assert prototype.panel_id == "prototype"
    assert prototype.session_id == page.session_id
    assert prototype.__meta__.state == :built

    assert {:ok, updated} =
             AshUi.Patch.Dispatch.run(page, {:row, prototype}, :toggle, %{},
               authorize?: false
             )

    assert updated.panel_id == "prototype"
    assert updated.session_id == page.session_id
    assert updated.open?
    assert updated.__meta__.state == :loaded
  end

  test "stored state enters rendering only through the declared relationship" do
    page = seed("identity")

    Panel
    |> Ash.Changeset.for_create(:mount, %{panel_id: "identity"},
      domain: AshUi.AshDomainFallback,
      authorize?: false,
      context: %{session_id: page.session_id}
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:toggle, %{},
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)

    assert render_text(page) =~ "identity:false"
    assert AshUi.view_load(Page) == [:panels]

    page =
      Ash.load!(page, AshUi.view_load(Page),
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )

    assert render_text(page) =~ "identity:true"
  end

  defp seed(panel_id) do
    Ash.Seed.seed!(Page, %{
      session_id: Ash.UUID.generate(),
      requested_panel_id: panel_id
    })
  end

  defp render_text(page) do
    assert {:ok, tree} =
             AshUi.Runtime.Rendering.render_tree(
               AshUi.Runtime.ResourceInfo.compiled_resource(Page),
               page,
               %{}
             )

    inspect(tree)
  end
end
