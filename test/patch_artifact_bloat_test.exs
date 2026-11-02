defmodule AshUi.PatchArtifactBloatTest do
  use ExUnit.Case, async: true

  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Table
  alias AshUi.ResourceBlueprint

  defmodule Row do
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
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
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:title, :string, allow_nil?: false, default: "Rows", public?: true)
      attribute(:visible?, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, create: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [title: title], [
            if visible? do
              each(rows, :row, [key: row.id], [
                button(:row, [title: row.label], [text(row.label)])
              ])
            else
              text(title)
            end
          ])
        )
      )
    end
  end

  test "compiled tables reference resources and slot ids instead of embedding subtrees" do
    table = Compiler.compile(Page)

    refute contains_resource_blueprint?(table)

    attrs_descriptors =
      for {_id, %{eval: {:element_attrs, descriptor}}} <- table.slots, do: descriptor

    assert attrs_descriptors != []
    assert Enum.all?(attrs_descriptors, &(&1.resource == Page))
    refute Enum.any?(attrs_descriptors, &Map.has_key?(&1, :compiled))

    branch = Enum.find_value(table.slots, fn {_id, slot} -> slot.kind == :branch && slot end)
    keyed = Enum.find_value(table.slots, fn {_id, slot} -> slot.kind == :keyed_list && slot end)

    assert is_list(branch.meta.arm_slot_ids)
    assert is_list(keyed.meta.item_slot_ids)
    refute Map.has_key?(branch.meta, :arm_slots)
    refute Map.has_key?(keyed.meta, :item_slots)

    referenced_ids = branch.meta.arm_slot_ids ++ keyed.meta.item_slot_ids
    assert Enum.all?(referenced_ids, &Map.has_key?(table.slots, &1))
    assert MapSet.disjoint?(MapSet.new(table.root_slot_ids), MapSet.new(keyed.meta.item_slot_ids))
    assert Table.item_slots(table, keyed) == Map.take(table.slots, keyed.meta.item_slot_ids)
  end

  test "runtime patch-table variants stay in one stable bounded cache term" do
    view = :bounded_variant_probe
    erase_patch_cache_terms(Page, view)
    on_exit(fn -> erase_patch_cache_terms(Page, view) end)

    for variant <- 1..64 do
      assert {:compiled_variant, ^variant} =
               AshUi.Compiled.cached_patch_table(
                 Page,
                 view,
                 {:test_target, ["/route/#{variant}"]},
                 fn -> {:compiled_variant, variant} end
               )
    end

    assert [{_key, {_blueprint_hash, variants}}] = patch_cache_terms(Page, view)
    assert length(variants) <= 16
  end

  defp contains_resource_blueprint?(%ResourceBlueprint{}), do: true

  defp contains_resource_blueprint?(%_{} = struct),
    do: struct |> Map.from_struct() |> contains_resource_blueprint?()

  defp contains_resource_blueprint?(map) when is_map(map),
    do:
      Enum.any?(map, fn {key, value} ->
        contains_resource_blueprint?(key) or contains_resource_blueprint?(value)
      end)

  defp contains_resource_blueprint?(list) when is_list(list),
    do: Enum.any?(list, &contains_resource_blueprint?/1)

  defp contains_resource_blueprint?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> contains_resource_blueprint?()

  defp contains_resource_blueprint?(_other), do: false

  defp patch_cache_terms(resource, view) do
    Enum.filter(:persistent_term.get(), fn
      {{:ash_ui_patch_table_cache, ^resource, ^view}, _value} -> true
      {{:ash_ui_patch_table, ^resource, _hash, ^view, _variant}, _value} -> true
      _other -> false
    end)
  end

  defp erase_patch_cache_terms(resource, view) do
    for {key, _value} <- patch_cache_terms(resource, view), do: :persistent_term.erase(key)
  end
end
