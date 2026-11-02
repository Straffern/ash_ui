defmodule AshUi.SafeHTMLExpressionTest do
  use ExUnit.Case, async: true
  import AshUi.ViewConstructor
  alias AshUi.RenderTarget
  alias AshUi.RenderTree
  alias AshUi.SafeHTML

  defmodule ContentShell do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ash_ui do
    end

    attributes do
      attribute(:body, :term,
        public?: true,
        description: "[opaque] test fixture — shape immaterial here"
      )
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(box(:root, [], [text(body)])))
    end
  end

  defmodule SafeHTMLPage do
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

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)

      attribute(:body, :term,
        public?: true,
        description: "[opaque] test fixture — shape immaterial here"
      )
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(box(:root, [], [text(body)])))
    end
  end

  test "component props preserve safe HTML text values" do
    {:ok, tree} =
      render_value_component(ContentShell, %{
        body: {:safe, "<strong>Bold</strong><em>md</em>"}
      })

    assert %RenderTree.Element{
             children: [%RenderTree.Text{content: {:safe, "<strong>Bold</strong><em>md</em>"}}]
           } = tree

    assert {:safe, iodata} = RenderTarget.Html.render_static(tree)
    assert IO.iodata_to_binary(iodata) =~ "<strong>Bold</strong><em>md</em>"
    refute IO.iodata_to_binary(iodata) =~ "&lt;strong&gt;"
  end

  test "component props preserve SafeHTML struct values" do
    safe = SafeHTML.new("<strong>Bold</strong><em>md</em>")

    assert {:ok, tree} =
             render_value_component(ContentShell, %{body: safe})

    assert %RenderTree.Element{children: [%RenderTree.Text{content: ^safe}]} = tree
    assert {:safe, iodata} = RenderTarget.Html.render_static(tree)
    assert IO.iodata_to_binary(iodata) =~ "<strong>Bold</strong><em>md</em>"
  end

  test "resource state expressions preserve safe HTML text values" do
    record =
      Ash.Seed.seed!(SafeHTMLPage, %{
        session_id: Ash.UUID.generate(),
        body: {:safe, "<strong>Bold</strong><em>md</em>"}
      })

    assert {:ok, tree} =
             AshUi.Runtime.Rendering.render_tree(
               AshUi.Runtime.ResourceInfo.compiled_resource(SafeHTMLPage),
               record,
               %{}
             )

    assert {:safe, iodata} = RenderTarget.Html.render_static(tree)
    html = IO.iodata_to_binary(iodata)
    assert html =~ "<strong>Bold</strong><em>md</em>"
    refute html =~ "&lt;strong&gt;"
  end

  test "dynamic text skeletons do not claim browser root-skip safety" do
    table = AshUi.Patch.Compiler.table(SafeHTMLPage)

    refute table.skeleton.root?
  end

  defp render_value_component(module, attrs) do
    with {:ok, record} <-
           AshUi.Runtime.ResourceComponentRender.build_resource_component_record(
             module,
             attrs,
             []
           ) do
      module
      |> AshUi.Compiled.resource!()
      |> AshUi.Runtime.Rendering.render_tree(record, %{},
        ash_resource_module: module,
        helper_module: module
      )
    end
  end
end
