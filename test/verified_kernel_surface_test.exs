defmodule AshUi.VerifiedKernelSurfaceTest do
  use ExUnit.Case, async: false
  import AshUi.ViewConstructor
  alias AshUi.RenderTarget
  alias AshUi.RenderTree
  alias AshUi.StaticCompile

  defmodule Shell do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:body, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(section(:root, [], [main(:body, [], [body])]))
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

    ash_ui do
    end

    actions do
      update(:set_composer) do
        argument(:value, :string, allow_nil?: false)
        change(set_attribute(:composer_text, arg(:value)))
      end
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:composer_text, :string, default: "")
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          render(Shell, %{
            body: [
              text("Body"),
              textarea(:composer_input, name: "text", on_change: :set_composer)
            ]
          })
        )
      )
    end
  end

  test "verified kernel source view includes tree-valued render inputs" do
    resource_view = StaticCompile.compile!(Page).view

    assert %{
             kind: :resource_component,
             resource: Shell,
             assigns: %{
               body: %{kind: :fragment, children: [%{kind: :text, content: "Body"}, _]}
             },
             client: []
           } = resource_view
  end

  test "verified kernel renders fragment inputs and caller event bindings" do
    record = Ash.Seed.seed!(Page, %{session_id: Ash.UUID.generate()})

    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(Page),
        record,
        %{}
      )

    assert %RenderTree.Element{
             tag: :section,
             meta: %{component_part: :root},
             children: [
               %RenderTree.Element{
                 tag: :main,
                 meta: %{component_part: :body},
                 children: [
                   %RenderTree.Fragment{
                     children: [
                       %RenderTree.Text{content: "Body"},
                       %RenderTree.Element{
                         tag: :textarea,
                         meta: %{component_part: :composer_input}
                       } = composer_input
                     ]
                   }
                 ]
               }
             ]
           } = tree

    assert [
             %AshUi.EventBinding{
               dom_event: :change,
               ui_event: :set_composer,
               meta: %{provides_value?: true}
             }
           ] = composer_input.event_bindings

    html = static_html(tree)
    assert html =~ ~r/data-ash-ui-on-change="ash_ui:dispatch:[^"]+\.change"/
    assert html =~ ~s"data-ash-ui-binding="
  end

  defp static_html(tree) do
    {:safe, iodata} = RenderTarget.Html.render_static(tree)
    IO.iodata_to_binary(iodata)
  end
end
