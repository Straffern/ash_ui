defmodule AshUi.DefectClass.DC37BindingsTest do
  @moduledoc """
  DC-37: registration-free event binding resolution. Live binding keys name
  the item/child chain + the element's stable lowered address; resolution
  walks the compiled patch table and re-evaluates the element's bindings
  against the CURRENT record — no render-time registration, no session
  binding store. Payload expressions therefore evaluate at DISPATCH time
  from live state, and the chunk evaluator emits exactly the keys the
  resolver accepts (round-trip).
  """
  use ExUnit.Case, async: false

  alias AshUi.EventBinding
  alias AshUi.Expr.Scope
  alias AshUi.Patch.Bindings
  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Runtime, as: PatchRuntime

  defmodule Row do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:message_id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule EventPage do
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
      attribute(:selected_id, :string, allow_nil?: false, default: "none", public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
        argument(:rows, {:array, Row}, allow_nil?: true)
        change(set_attribute(:rows, arg(:rows), set_when_nil?: false))
      end

      update :select do
        require_atomic?(false)
        argument(:id, :string, allow_nil?: false)
        change(set_attribute(:selected_id, arg(:id)))
      end

      update :clear do
        require_atomic?(false)
        change(set_attribute(:selected_id, "none"))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [part: :dc37_root], [
            button(:pick, [type: :button, on_click: :select, action_input: %{id: selected_id}], [
              text("pick")
            ]),
            list(:rows, [part: :dc37_rows], [
              each(rows, :row, [], [
                item(
                  :entry,
                  [part: :dc37_row, on_click: :select, action_input: %{id: row.message_id}],
                  [text(row.label)]
                )
              ])
            ])
          ])
        )
      )
    end
  end

  defp seed(rows) do
    Ash.Seed.seed!(EventPage, %{
      session_id: Ash.UUID.generate(),
      rows: Enum.map(rows, &struct(Row, &1))
    })
  end

  test "top-level binding resolves and evaluates payload from the CURRENT record" do
    table = Compiler.table(EventPage)
    page = seed([%{message_id: "m1", label: "one"}])

    button_addr =
      table.event_elements
      |> Enum.find(fn {_addr, entry} -> entry.eaches == [] end)
      |> elem(0)

    key = Compiler.addr_component(button_addr) <> ".click"

    assert {:ok, %EventBinding{dom_event: :click} = binding, {:root}} =
             Bindings.resolve(page, key)

    assert inspect(binding.args_exprs) =~ "none"

    # dispatch-time evaluation: payload follows live state
    page2 =
      page
      |> Ash.Changeset.for_update(:select, %{id: "m1"},
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )
      |> Ash.update!(domain: AshUi.AshDomainFallback)

    assert {:ok, %EventBinding{} = binding2, {:root}} = Bindings.resolve(page2, key)
    refute binding2.args_exprs == binding.args_exprs
  end

  test "item binding resolves by primary key with the item bound in scope" do
    table = Compiler.table(EventPage)
    page = seed([%{message_id: "m1", label: "one"}, %{message_id: "m2", label: "two"}])

    {row_addr, entry} = Enum.find(table.event_elements, fn {_a, e} -> e.eaches != [] end)
    assert [%{as: :row}] = entry.eaches

    key =
      EventBinding.key_component("m2") <>
        "." <> Compiler.addr_component(row_addr) <> ".click"

    assert {:ok, %EventBinding{dom_event: :click} = binding, {:root}} =
             Bindings.resolve(page, key)

    assert inspect(binding.args_exprs) =~ "m2",
           "expected item payload for m2, got: #{inspect(binding.args_exprs)}"

    # unknown item key fails as an ordinary unknown target
    missing =
      EventBinding.key_component("zz") <> "." <> Compiler.addr_component(row_addr) <> ".click"

    assert :error = Bindings.resolve(page, missing)
  end

  test "chunk evaluator emits exactly the keys the resolver accepts (round-trip)" do
    table = Compiler.table(EventPage)
    page = seed([%{message_id: "m7", label: "seven"}])

    {row_addr, _entry} = Enum.find(table.event_elements, fn {_a, e} -> e.eaches != [] end)

    {_id, slot} =
      Enum.find(table.slots, fn
        {_id, %{kind: :keyed_list}} -> true
        _other -> false
      end)

    [row] = page.rows

    item_scope =
      Scope.new(row, %{},
        ash_resource_module: EventPage,
        item_bindings: %{slot.meta.as => row},
        context: %{__bp_binding_chain__: [EventBinding.key_component("m7")]}
      )

    {_sid, attrs_slot} =
      table
      |> AshUi.Patch.Table.item_slots(slot)
      |> Enum.find(fn
        {_id, %{kind: :attrs, addr: ^row_addr}} -> true
        _other -> false
      end)

    attrs = AshUi.Patch.Evaluator.eval(attrs_slot.eval, item_scope)
    assert attrs =~ "binding"

    [_, emitted_key] =
      Regex.run(~r/data-ash-ui-binding="([^"]+)"/, attrs)

    assert {:ok, %EventBinding{dom_event: :click} = binding, {:root}} =
             Bindings.resolve(page, emitted_key)

    assert inspect(binding.args_exprs) =~ "m7"
  end

  test "PatchRuntime.changed_addresses reaches exactly the propagation-affected slots" do
    table = Compiler.table(EventPage)
    page = seed([%{message_id: "m1", label: "one"}])

    updated = %{page | selected_id: "m1"}
    changed = PatchRuntime.changed_addresses(table, page, updated)

    # selected_id is read ONLY in an event payload here: payload deps do
    # not invalidate (the serialized binding key is stable; payloads
    # evaluate at dispatch time) — nothing in the DOM changes, so the
    # changed set is EMPTY. Payload freshness is gated separately above.
    assert changed == MapSet.new()

    assert PatchRuntime.changed_addresses(table, nil, updated) == :all
  end
end
