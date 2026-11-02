defmodule AshUi.DslErgonomicsTest do
  use ExUnit.Case, async: false
  import AshUi.Expr
  import AshUi.ViewConstructor
  alias AshUi.EventBinding
  alias AshUi.RenderTree
  alias AshUi.Runtime.Rendering
  alias AshUi.Runtime.ResourceInfo

  defp constructor_node(compiled), do: AshUi.ViewConstructor.lower(compiled)

  defmodule Panel do
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
        expr(box(:panel_root, [], [box(:panel_body, [], [body])]))
      )
    end
  end

  defmodule ItemList do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:rows, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(box(:root, [], [rows]))
      )
    end
  end

  defmodule Summary do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:title, :string, allow_nil?: false, public?: true)
      attribute(:route_id, :string, allow_nil?: false, public?: true)
      attribute(:user_email, :string, allow_nil?: false, public?: true)
      attribute(:body, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [data: [route_id: route_id, user_email: user_email]], [
            heading(:title, [level: 2], [text(title)]),
            body
          ])
        )
      )
    end
  end

  defmodule InlineCard do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(article(:root, [], [heading(:title, [level: 2], [text("Title")])]))
      )
    end
  end

  defmodule RawReferencePage do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

    ets do
      private?(true)
    end

    ash_ui do
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:artist_id, :string)
      attribute(:title, :string, default: "Draft title")
      attribute(:items, {:array, :map}, default: [%{label: "First"}, %{label: "Second"}])
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    route do
      param(:artist_id, :string, state: :artist_id)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          render(
            Summary,
            %{
              title: title,
              route_id: artist_id,
              user_email: path(context(:current_user), [:email]),
              body: [
                input(:title_input,
                  type: :text,
                  name: "title",
                  value: title,
                  data: [
                    route_id: artist_id,
                    user_email: path(context(:current_user), [:email])
                  ]
                ),
                each(items, :item, [], [text(item.label)])
              ]
            }
          )
        )
      )
    end
  end

  defmodule ImportedTemplatePage do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

    ets do
      private?(true)
    end

    ash_ui do
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:open?, :boolean, default: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          render(Panel, %{
            body:
              if open? do
                button([mark(:open, when: open?), text("Open")])
              else
                paragraph(:empty, [], [text("Closed")])
              end
          })
        )
      )
    end
  end

  defmodule FragmentRowsPage do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

    ets do
      private?(true)
    end

    ash_ui do
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)

      attribute(:items, {:array, :map},
        default: [%{label: "Inbox", selected?: true}, %{label: "Archive", selected?: false}]
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
          render(ItemList, %{
            rows:
              each(items, :entry, [index: :entry_index], [
                button(
                  :entry_button,
                  [type: :button, state: [selected: entry.selected?]],
                  [text(entry.label), text(to_string(index(:entry_index)))]
                )
              ])
          })
        )
      )
    end
  end

  test "value resources can receive fragment values" do
    resource = AshUi.compile!(ImportedTemplatePage)

    assert %{kind: :resource_component, resource: Panel, assigns: %{body: %{kind: :if}}} =
             resource.view

    record = Ash.Seed.seed!(ImportedTemplatePage, %{session_id: Ash.UUID.generate()})

    {:ok, tree} =
      Rendering.render_tree(ResourceInfo.compiled_resource(ImportedTemplatePage), record, %{})

    assert %RenderTree.Element{
             tag: :div,
             meta: %{component_part: :panel_root},
             children: [
               %RenderTree.Element{
                 tag: :div,
                 meta: %{component_part: :panel_body},
                 children: [
                   %RenderTree.Element{
                     tag: :button,
                     attrs: %{"aria-expanded" => "true"}
                   }
                 ]
               }
             ]
           } = tree
  end

  test "event option sugar is normalized for semantic elements and buttons" do
    assert %{events: [%EventBinding{dom_event: :click, ui_event: :save}]} =
             constructor_node(expr(button(:save_button, on_click: :save)))

    assert %{events: [%EventBinding{dom_event: :submit, ui_event: :save}]} =
             constructor_node(expr(form(:save_form, on_submit: :save)))

    assert %{events: [%EventBinding{dom_event: :click, ui_event: :save}]} =
             AshUi.ViewConstructor.button([on_click: :save], [])
  end

  test "fragment inputs compose inside caller-owned each scopes" do
    record = Ash.Seed.seed!(FragmentRowsPage, %{session_id: Ash.UUID.generate()})

    {:ok, tree} =
      Rendering.render_tree(ResourceInfo.compiled_resource(FragmentRowsPage), record, %{})

    assert [selected, archive] = collect_elements(tree, :button)
    assert rendered_text(selected) == "Inbox0"
    assert archive.attrs["type"] == :button
    assert rendered_text(archive) == "Archive1"
  end

  test "simple DSL references are first-class values without expr wrappers" do
    record =
      Ash.Seed.seed!(RawReferencePage, %{
        session_id: Ash.UUID.generate(),
        artist_id: "artist-1"
      })

    assert {:ok, tree} =
             Rendering.render_tree(
               ResourceInfo.compiled_resource(RawReferencePage),
               record,
               %{},
               context: %{current_user: %{email: "admin@example.test"}}
             )

    assert [
             %RenderTree.Element{
               tag: :section,
               attrs: %{"data-route-id" => "artist-1", "data-user-email" => "admin@example.test"}
             }
           ] = collect_elements(tree, :section)

    assert rendered_text(tree) == "Draft titleFirstSecond"
    assert [%RenderTree.Element{attrs: input_attrs}] = collect_elements(tree, :input)
    assert input_attrs["value"] == "Draft title"
    assert input_attrs["data-route-id"] == "artist-1"
    assert input_attrs["data-user-email"] == "admin@example.test"
  end

  test "inline part tags are preserved in value-resource view contracts" do
    resource = AshUi.compile!(InlineCard)

    assert %{
             meta: %{component_part: :root},
             children: [%{meta: %{component_part: :title}}]
           } = resource.view
  end

  defp collect_elements(%RenderTree.Element{tag: tag, children: children} = node, tag) do
    [node | Enum.flat_map(children, &collect_elements(&1, tag))]
  end

  defp collect_elements(%{children: children}, tag) do
    Enum.flat_map(children, &collect_elements(&1, tag))
  end

  defp collect_elements(_node, _tag) do
    []
  end

  defp rendered_text(%RenderTree.Text{content: content}) do
    to_string(content)
  end

  defp rendered_text(%{children: children}) do
    Enum.map_join(children, &rendered_text/1)
  end

  defp rendered_text(_node) do
    ""
  end
end
