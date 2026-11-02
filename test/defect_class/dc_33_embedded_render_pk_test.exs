defmodule AshUi.DefectClass.DC33EmbeddedRenderPkTest do
  use ExUnit.Case, async: false

  defmodule Fold do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:name, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:collapsed?, :boolean, allow_nil?: false, default: false, public?: true)
      attribute(:label, :string, public?: true)
    end

    actions do
      create(:create) do
        primary?(true)
        accept([:name, :collapsed?, :label])
      end

      update(:toggle) do
        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :collapsed?, !changeset.data.collapsed?)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(text(name <> ":" <> to_string(collapsed?) <> ":" <> coalesce(label, "nil")))
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
      attribute(:folds, {:array, Fold}, allow_nil?: false, default: [], public?: true)
      attribute(:requested_name, :string, allow_nil?: false, public?: true)
      attribute(:input_label, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:update])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          render(Fold, %{
            name: requested_name,
            collapsed?: false,
            label: input_label
          })
        )
      )
    end
  end

  defmodule ScalarPage do
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
      attribute(:scalar_fold, Fold, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(render(Fold, scalar_fold)))
    end
  end

  test "stored array element wins while input overlays nil stored fields" do
    record =
      seed(%{
        requested_name: "left",
        input_label: "from-input",
        folds: [%{name: "left", collapsed?: true, label: nil}]
      })

    assert render_text(Page, record) =~ "left:true:from-input"
  end

  test "absent primary key casts input and defaults" do
    record = seed(%{requested_name: "new", input_label: "fresh", folds: []})
    assert render_text(Page, record) =~ "new:false:fresh"
  end

  test "embedded update followed by render reads the changed parent attribute" do
    record = seed(%{requested_name: "round", folds: [%{name: "round", collapsed?: false}]})
    assert render_text(Page, record) =~ "round:false:nil"

    updated = embedded_dispatch!(record, [:folds, {:item, "round"}], :toggle, %{})

    assert render_text(Page, updated) =~ "round:true:nil"
  end

  test "scalar embedded bare ref renders the stored value" do
    record =
      Ash.Seed.seed!(ScalarPage, %{
        session_id: Ash.UUID.generate(),
        scalar_fold: %{name: "scalar", collapsed?: true, label: "stored"}
      })

    assert render_text(ScalarPage, record) =~ "scalar:true:stored"
  end

  defp seed(attrs) do
    Ash.Seed.seed!(Page, Map.put(attrs, :session_id, Ash.UUID.generate()))
  end

  # ENGINE GAP: no surviving executor runs an embedded instance's action as
  # a parent update (deleted with the Runtime facade; see DC-31).
  defp embedded_dispatch!(record, path, action, params) do
    {:ok, updated} =
      AshUi.Patch.Dispatch.embedded_update(record, path, action, params, authorize?: false)

    updated
  end

  defp render_text(module, record) do
    assert {:ok, tree} =
             AshUi.Runtime.Rendering.render_tree(
               AshUi.Runtime.ResourceInfo.compiled_resource(module),
               record,
               %{}
             )

    inspect(tree)
  end
end
