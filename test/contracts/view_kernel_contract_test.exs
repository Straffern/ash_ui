defmodule AshUi.Contracts.ViewKernelContractTest do
  use ExUnit.Case, async: true
  import AshUi.ViewConstructor
  alias AshUi.ViewConstructor, as: View

  defmodule ChildPage do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

    ets do
      private?(true)
    end

    ash_ui do
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:label, :string, default: "child")
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text(label)))
    end
  end

  defmodule ActionButton do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ash_ui do
    end

    attributes do
      attribute(:label, :string, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          button(:root, [type: :button], [
            inline(:label, [data: [role: "button-label"]], [text(label)])
          ])
        )
      )
    end
  end

  defmodule KernelPage do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

    ets do
      private?(true)
    end

    ash_ui do
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:title, :string, default: "Draft")
      attribute(:items, {:array, :map}, default: [%{label: "one"}, %{label: "two"}])
    end

    relationships do
      has_one(:badge, ChildPage,
        source_attribute: :session_id,
        destination_attribute: :session_id,
        public?: true
      )
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
            box(:row, [], [text(title)]),
            if true do
              render(ChildPage, badge)
            else
              nothing()
            end,
            each(items, :item, [], [text(item.label)]),
            render(ActionButton, %{label: "Raw"})
          ])
        )
      )
    end
  end

  test "the implemented view kernel renders end to end with template-source tags" do
    refute function_exported?(View, :tag, 4)
    refute function_exported?(View, :element, 4)
    refute function_exported?(View, :unsafe_element, 4)

    session_id = Ash.UUID.generate()

    record =
      KernelPage
      |> Ash.Seed.seed!(%{
        session_id: session_id,
        title: "Live",
        items: [%{label: "Ada"}, %{label: "Grace"}]
      })
      |> Map.put(
        :badge,
        Ash.Seed.seed!(ChildPage, %{session_id: session_id, label: "Nested"})
      )

    assert {:ok,
            %{
              kind: :element,
              tag: :div,
              meta: %{component_part: :stack},
              children: [
                %{
                  kind: :element,
                  tag: :div,
                  meta: %{component_part: :row},
                  children: [%{kind: :text, content: "Live"}]
                },
                %{
                  kind: :component,
                  component: ChildPage,
                  view: %{kind: :text, content: "Nested"}
                },
                %{
                  kind: :fragment,
                  children: [
                    %{key: 0, kind: :text, content: "Ada"},
                    %{key: 1, kind: :text, content: "Grace"}
                  ]
                },
                %{
                  kind: :component,
                  component: ActionButton,
                  view: %{
                    kind: :element,
                    tag: :button,
                    attrs: %{"type" => :button},
                    events: [],
                    meta: %{
                      component_part: :root,
                      component_part_states: []
                    },
                    children: [
                      %{
                        kind: :element,
                        tag: :span,
                        attrs: %{"data-role" => "button-label"},
                        events: [],
                        meta: %{
                          component_part: :label,
                          component_part_states: []
                        },
                        children: [%{kind: :text, content: "Raw"}]
                      }
                    ]
                  }
                }
              ]
            }} =
             AshUi.Runtime.Rendering.render_view(
               AshUi.Runtime.ResourceInfo.compiled_resource(KernelPage),
               record,
               %{}
             )
  end

  test "unsupported target-state nodes are rejected instead of drifting into the runtime" do
    unsupported_nodes = [
      %{kind: :grid, children: []},
      %{kind: :section, children: []},
      %{kind: :switch, cases: []},
      %{kind: :case, condition: true, child: %{kind: :text, content: "x"}},
      %{kind: :default, child: %{kind: :text, content: "x"}},
      %{kind: :portal, target: :sidebar, children: []},
      %{kind: :heading, level: 1, content: "title"},
      %{kind: :divider},
      %{kind: :spacer},
      %{kind: :actions, children: []},
      %{kind: :action, action: :save},
      %{kind: :submit},
      %{kind: :outlet_auth_page},
      %{kind: :outlet, child: :active_page}
    ]

    Enum.each(unsupported_nodes, fn node ->
      assert {:error, message: message} =
               Ash.Type.apply_constraints(AshUi.Type.RenderTree, node, [])

      assert message =~ "invalid render tree"
    end)
  end
end
