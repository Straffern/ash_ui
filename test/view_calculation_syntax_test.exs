defmodule AshUi.ViewCalculationSyntaxTest.NotificationsBell do
  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

  ets do
    private?(true)
  end

  ash_ui do
  end

  attributes do
    attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text("bell")))
  end
end

defmodule AshUi.ViewCalculationSyntaxTest.MusicShell do
  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

  ets do
    private?(true)
  end

  ash_ui do
  end

  attributes do
    attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
  end

  relationships do
    has_one(:notifications_bell, AshUi.ViewCalculationSyntaxTest.NotificationsBell,
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
          text("header"),
          if not is_nil(^context(:current_user)) do
            render(AshUi.ViewCalculationSyntaxTest.NotificationsBell, notifications_bell)
          else
            nothing()
          end
        ])
      )
    )
  end
end

defmodule AshUi.ViewCalculationSyntaxTest do
  use ExUnit.Case, async: false
  alias AshUi.Runtime.Rendering
  alias AshUi.Runtime.ResourceInfo

  test "static compile and runtime preserve exact source box syntax without manual imports" do
    resource_view =
      AshUi.StaticCompile.compile!(AshUi.ViewCalculationSyntaxTest.MusicShell).view

    assert %{
             kind: :element,
             tag: :div,
             part: :stack,
             children: [
               %{kind: :text, content: "header"},
               %{
                 kind: :if,
                 condition: %AshUi.Expr.Compiled{deps: [context: [:current_user]]},
                 then: %{
                   kind: :resource_component,
                   resource: AshUi.ViewCalculationSyntaxTest.NotificationsBell
                 },
                 else: %{kind: :fragment, children: []}
               }
             ]
           } = resource_view

    compiled = ResourceInfo.compiled_resource(AshUi.ViewCalculationSyntaxTest.MusicShell)

    shell =
      Ash.Seed.seed!(AshUi.ViewCalculationSyntaxTest.MusicShell, %{
        session_id: Ash.UUID.generate()
      })

    assert {:ok,
            %{
              kind: :element,
              tag: :div,
              children: [%{kind: :text, content: "header"}]
            }} = Rendering.render_view(compiled, shell, %{}, context: %{current_user: nil})

    bell =
      Ash.Seed.seed!(AshUi.ViewCalculationSyntaxTest.NotificationsBell, %{
        session_id: Ash.UUID.generate()
      })

    authed_shell = Map.put(shell, :notifications_bell, bell)

    assert {:ok,
            %{
              kind: :element,
              tag: :div,
              children: [
                %{kind: :text, content: "header"},
                %{
                  kind: :component,
                  component: AshUi.ViewCalculationSyntaxTest.NotificationsBell,
                  view: %{kind: :text, content: "bell"}
                }
              ]
            }} =
             Rendering.render_view(compiled, authed_shell, %{},
               context: %{current_user: %{id: "user-1"}}
             )
  end
end
