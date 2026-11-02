defmodule AshUi.Contracts.BlueprintContractTest do
  use ExUnit.Case, async: true
  import AshUi.ViewConstructor

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    ash_ui do
    end

    resource do
      short_name(:contract_page)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:title, :string, default: "draft")
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text(title)))
    end
  end

  defmodule PlainResource do
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:title, :string)
    end
  end

  defmodule ContractDefinitions do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, public?: true)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(box(:row, [], [text(label)])))
    end
  end

  test "resource and value-resource blueprints are the public normalized contracts" do
    resource = AshUi.compile!(Page)
    value_resource = AshUi.compile!(ContractDefinitions)
    assert %AshUi.ResourceBlueprint{} = resource
    assert resource.id == :contract_page
    assert resource.name == :contract_page
    assert resource.module == Page
    refute Map.has_key?(Map.from_struct(resource), :table)
    refute Map.has_key?(Map.from_struct(resource), :theme)
    assert resource.stylesheets == []
    assert %AshUi.ResourceBlueprint{} = value_resource
    assert value_resource.module == ContractDefinitions
    assert value_resource.view.kind == :element
    assert value_resource.view.meta.component_part == :row
  end

  test "public resource compilation preserves normalized contract semantics across modules and compiled contracts" do
    compiled_resource = AshUi.compile!(ContractDefinitions)
    assert %AshUi.ResourceBlueprint{} = compiled_resource
    assert compiled_resource.module == ContractDefinitions
    assert compiled_resource.view.kind == :element
    assert compiled_resource.view.meta.component_part == :row
    assert AshUi.compile!(compiled_resource.module).view == compiled_resource.view
  end

  test "value-resource rendering preserves reusable UI semantics" do
    assert {:ok, record} =
             AshUi.Runtime.ResourceComponentRender.build_resource_component_record(
               ContractDefinitions,
               %{label: "Hi"},
               []
             )

    assert {:ok, tree} =
             ContractDefinitions
             |> AshUi.Compiled.resource!()
             |> AshUi.Runtime.Rendering.render_tree(
               record,
               %{},
               ash_resource_module: ContractDefinitions,
               helper_module: ContractDefinitions
             )

    assert %AshUi.RenderTree.Element{
             children: [%AshUi.RenderTree.Text{content: "Hi"}]
           } = tree
  end

  test "public AshUi facade stays focused on top-level compile helpers" do
    refute Code.ensure_loaded?(AshUi.Spec)
    refute function_exported?(AshUi, :component_definition!, 1)
    refute function_exported?(AshUi, :theme_definition!, 1)
    assert function_exported?(AshUi, :compile!, 1)
    refute function_exported?(AshUi, :compile_app!, 1)
    refute function_exported?(AshUi, :compile_component!, 1)
    refute function_exported?(AshUi, :render_component, 2)
    refute function_exported?(AshUi, :compile_theme!, 1)
    refute Code.ensure_loaded?(AshUi.Theme)
    refute Code.ensure_loaded?(AshUi.ThemeBlueprint)
    refute Code.ensure_loaded?(AshUi.Runtime.ThemeResolver)
  end

  test "public resource compilation accepts only AshUi extension modules" do
    assert_raise ArgumentError, ~r"static AshUi module", fn ->
      AshUi.compile!(PlainResource)
    end

    assert_raise ArgumentError, ~r"extensions: \[AshUi\]", fn ->
      AshUi.StaticCompile.resource_definition!(PlainResource)
    end
  end

  test "public resource compilation rejects map-driven resource definitions" do
    assert_raise ArgumentError, ~r"static AshUi modules", fn ->
      AshUi.compile!(%{
        name: :invalid_read_mode,
        reads: [%{name: :artists, mode: :eventual}]
      })
    end
  end
end
