defmodule AshUi.DefectClass.DC40CalculateBoundaryTest do
  @moduledoc """
  DC-40: `Ash.calculate(row, :view)` — the public policy-checked boundary —
  must work for EVERY page shape the bridge renders, specifically
  session-pk entities with `manual`/`no_attributes?` relationships. Ash's
  calc-dependency loader force-selects dep relationships' source
  attributes (has_many defaults `:id`), so the calculation must load its
  derived dependency set itself through the plain load path. Found by two
  independent consumer cutovers (pdf_annotator, search).
  """
  use ExUnit.Case, async: false

  defmodule Doc do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, allow_nil?: false, default: "", public?: true)

      attribute(:projected?, :boolean,
        allow_nil?: false,
        default: false,
        public?: true
      )
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule ManualDocs do
    @moduledoc false
    use Ash.Resource.ManualRelationship

    @impl true
    def load(records, _opts, _context) do
      docs =
        Ash.read!(Doc, domain: AshUi.AshDomainFallback, authorize?: false)
        |> Enum.map(&%{&1 | projected?: true})

      {:ok, Enum.map(records, fn _record -> docs end)}
    end
  end

  defmodule Viewer do
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
      attribute(:heading, :string, allow_nil?: false, default: "h", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :docs, Doc do
        no_attributes?(true)
        public?(true)
      end

      has_many :manual_docs, Doc do
        manual(ManualDocs)
        no_attributes?(true)
        public?(true)
      end
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
          section(:root, [], [
            heading(:h, [], [text(heading)]),
            list(:docs, [], [each(docs, :doc, [], [item(:row, [], [text(doc.title)])])]),
            list(:mdocs, [], [
              each(manual_docs, :doc, [], [
                item(:mrow, [], [
                  text(doc.title),
                  if doc.projected? do
                    text("projected")
                  else
                    text("not-projected")
                  end
                ])
              ])
            ])
          ])
        )
      )
    end
  end

  test "Ash.calculate(:view) works on session-pk pages with manual relationships" do
    Ash.Seed.seed!(Doc, %{title: "manual-visible"})
    viewer = Ash.Seed.seed!(Viewer, %{session_id: Ash.UUID.generate()})

    assert {:ok, tree} =
             Ash.calculate(viewer, :view,
               domain: AshUi.AshDomainFallback,
               authorize?: false
             )

    {:safe, iodata} =
      AshUi.RenderTarget.Html.render_static(tree)

    html = IO.iodata_to_binary(iodata)
    assert html =~ "manual-visible"
    assert html =~ "projected"
    refute html =~ "not-projected"

    assert AshUi.view_load(Viewer) == [
             {:docs, [:projected?, :title]},
             :manual_docs
           ]

    # the boundary and the host render pipeline agree byte-for-byte
    loaded =
      Ash.load!(viewer, AshUi.view_load(Viewer),
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )

    {:ok, pipeline_tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(Viewer),
        loaded,
        %{},
        []
      )

    {:safe, pipeline_iodata} =
      AshUi.RenderTarget.Html.render_static(pipeline_tree)

    assert html == IO.iodata_to_binary(pipeline_iodata)
  end

  test "already-loaded values are reused (lazy) — no requery clobber" do
    viewer = Ash.Seed.seed!(Viewer, %{session_id: Ash.UUID.generate()})

    loaded =
      Ash.load!(viewer, AshUi.view_load(Viewer),
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )

    assert {:ok, _tree} =
             Ash.calculate(loaded, :view,
               domain: AshUi.AshDomainFallback,
               authorize?: false
             )
  end
end
