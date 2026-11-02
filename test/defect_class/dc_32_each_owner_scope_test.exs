defmodule AshUi.DefectClass.DC32EachOwnerScopeTest do
  use ExUnit.Case, async: true

  defmodule Entry do
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, public?: true)
    end
  end

  defmodule Settings do
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:prefix, :string, allow_nil?: false, public?: true)
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
      attribute(:entries, {:array, Entry}, allow_nil?: false, default: [], public?: true)
      attribute(:settings, Settings, allow_nil?: false, public?: true)
      attribute(:selected_id, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      update(:select) do
        argument(:id, :string, allow_nil?: false)
        change(set_attribute(:selected_id, arg(:id)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          each(entries, :entry, [], [
            button(
              :entry,
              [on_click: :select, action_input: %{id: entry.id}],
              [text(settings.prefix <> entry.label)]
            )
          ])
        )
      )
    end
  end

  test "each item fields and enclosing-resource fields/actions share the owner view scope" do
    record =
      Ash.Seed.seed!(Page, %{
        session_id: Ash.UUID.generate(),
        entries: [%Entry{id: "one", label: "First"}],
        settings: %Settings{prefix: "Owner: "}
      })

    assert {:ok, tree} =
             AshUi.Runtime.Rendering.render_tree(
               AshUi.Runtime.ResourceInfo.compiled_resource(Page),
               record,
               %{}
             )

    assert inspect(tree) =~ "Owner: First"

    # registration-free: resolve the item element's binding from the
    # compiled table with the item bound by primary key
    table = AshUi.Patch.Compiler.table(Page)
    {addr, _entry} = Enum.find(table.event_elements, fn {_a, e} -> e.eaches != [] end)

    key =
      AshUi.EventBinding.key_component("one") <>
        "." <> AshUi.Patch.Compiler.addr_component(addr) <> ".click"

    assert {:ok, binding, {:root}} = AshUi.Patch.Bindings.resolve(record, key)
    assert binding.ui_event == :select
    assert binding.args_exprs == %{id: "one"}
  end
end
