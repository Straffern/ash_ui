defmodule AshUi.IslandContractTest do
  use ExUnit.Case, async: false

  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Runtime

  defmodule Page do
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
      attribute(:title, :string, allow_nil?: false, default: "Workbench", public?: true)
      attribute(:rev, :integer, allow_nil?: false, default: 1, public?: true)
      attribute(:unrelated, :string, allow_nil?: false, default: "", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :apply_engine_state do
        require_atomic?(false)
        argument(:title, :string, allow_nil?: false)
        argument(:rev, :integer, allow_nil?: false)
        change(set_attribute(:title, arg(:title)))
        change(set_attribute(:rev, arg(:rev)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:shell, [], [
            island(
              "workbench-gl",
              props: %{manifest: %{title: title}, rev: rev},
              on: [engine_state: :apply_engine_state]
            )
          ])
        )
      )
    end
  end

  defp unique_module(name) do
    suffix = "M#{System.unique_integer([:positive])}"
    Module.concat([__MODULE__, name, suffix])
  end

  defp render_html(record) do
    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(Page),
        record,
        %{},
        target: AshUi.RenderTarget.Static
      )

    {:safe, iodata} =
      AshUi.RenderTarget.Html.render_static(
        tree,
        target: AshUi.RenderTarget.Static
      )

    IO.iodata_to_binary(iodata)
  end

  test "renders a stable ignored root with serialized props and event bindings" do
    html = render_html(%Page{session_id: "session", title: "Workbench", rev: 3})

    assert html =~ ~s(id="ash-ui-island-sd29ya2JlbmNoLWds")
    assert html =~ ~s(data-ash-ui-client-hook="AshUiIsland")
    assert html =~ ~s(data-ash-ui-dom-update="ignore")
    assert html =~ ~s(data-ash-ui-island="workbench-gl")
    assert html =~ ~s(data-ash-ui-island-events="{&quot;engine_state&quot;:)
    assert html =~ ~s(data-ash-ui-island-props="{)
    assert html =~ ~s(&quot;manifest&quot;:)
    assert html =~ ~s(&quot;title&quot;:&quot;Workbench&quot;)
    assert html =~ ~s(&quot;rev&quot;:3)
    assert html =~ ~r/<div[^>]*data-ash-ui-island="workbench-gl"[^>]*><\/div>/
  end

  test "props expressions participate in dependency tracking" do
    table = Compiler.table(Page)
    page = %Page{session_id: "session", title: "Workbench", rev: 1, unrelated: ""}

    changed_title = Runtime.changed_addresses(table, page, %{page | title: "Messages"})
    changed_rev = Runtime.changed_addresses(table, page, %{page | rev: 2})
    unchanged = Runtime.changed_addresses(table, page, %{page | unrelated: "ignored"})

    props_address = "v/0@data-ash-ui-island-props"

    assert MapSet.member?(changed_title, props_address)
    assert MapSet.member?(changed_rev, props_address)
    assert unchanged == MapSet.new()
    assert render_html(%{page | title: "Messages"}) =~ "&quot;title&quot;:&quot;Messages&quot;"
  end

  test "unknown island actions fail at compile time with a clear binding error" do
    module = unique_module(UnknownIslandAction)

    source = """
    defmodule #{inspect(module)} do
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
      end

      identities do
        identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
      end

      calculations do
        calculate(
          :view,
          AshUi.Type.RenderTree,
          expr(island("unknown-event", on: [mystery: :missing_action]))
        )
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end
    assert Exception.message(error) =~ "event binding targets unknown action `:missing_action`"
  end

  test "island options use a closed schema" do
    module = unique_module(UnknownIslandOption)

    source = """
    defmodule #{inspect(module)} do
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
      end

      identities do
        identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
      end

      calculations do
        calculate(
          :view,
          AshUi.Type.RenderTree,
          expr(island("bad-options", children: []))
        )
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end
    assert Exception.message(error) =~ "unknown options [:children]"
    assert Exception.message(error) =~ "expected only :props and :on"
  end
end
