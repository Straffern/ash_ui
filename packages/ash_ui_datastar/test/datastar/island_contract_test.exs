defmodule AshUi.Datastar.IslandContractTest do
  use ExUnit.Case, async: false

  alias AshUi.Datastar.{FragmentRender, RenderTarget, SSE}
  alias AshUi.Patch.Compiler

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
      attribute(:count, :integer, allow_nil?: false, default: 1, public?: true)
      attribute(:alternate?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:shell, [], [
            if alternate? do
              section(:alternate, [], [
                island("counter", props: %{count: count})
              ])
            else
              section(:primary, [], [
                island("counter", props: %{count: count})
              ])
            end
          ])
        )
      )
    end
  end

  defp page(attrs \\ %{}) do
    struct(
      Page,
      Map.merge(
        %{session_id: Ash.UUID.generate(), count: 1, alternate?: false},
        attrs
      )
    )
  end

  defp table, do: Compiler.table(Page, target: RenderTarget)

  test "mount lowers client-owned DOM intent to Datastar ignore morph" do
    html = FragmentRender.full_render(page(), table())

    assert html =~ ~s(data-ignore-morph="ignore")
    assert html =~ ~s(data-ash-ui-island="counter")
    assert html =~ ~s(data-ash-ui-client-hook="AshUiIsland")
    refute html =~ "data-ash-ui-dom-update"
    refute html =~ ~s(data-init="AshUiIsland")
  end

  test "props-only change sets one island attribute without an outer root morph" do
    old = page()

    assert [%SSE.Event{meta: %{operation: :island_props}} = event] =
             FragmentRender.patch(old, %{old | count: 2}, table())

    wire = SSE.encode(event)
    assert wire =~ "setAttribute('data-ash-ui-island-props'"
    assert wire =~ "\\\"count\\\":2"
    refute wire =~ ~s(<div)
    refute wire =~ "selector #ash-ui-island"
  end

  test "branch widening around an island falls back to an outer morph" do
    old = page()

    assert [%SSE.Event{} = event] =
             FragmentRender.patch(old, %{old | alternate?: true}, table())

    wire = SSE.encode(event)
    refute wire =~ "mode remove"
    refute wire =~ "mode replace"
    refute wire =~ "mode before"
    refute wire =~ "mode after"
    assert wire =~ "data-ignore-morph=\"ignore\""
  end
end
