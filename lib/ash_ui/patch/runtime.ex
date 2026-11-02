defmodule AshUi.Patch.Runtime do
  @moduledoc """
  Change derivation over a compiled `AshUi.Patch.Table`.

  The patching protocol is the live host's own: the compiled skeleton supplies
  statics, evaluator closures supply dynamics, and the ONLY thing this
  module contributes is the changed-address set — which dynamics may
  return a value instead of nil under change tracking. The live host's diff
  engine and client own every DOM decision; there is no parallel op
  vocabulary, no slot-value store, no tree.

  `diff/2` compares attributes AND loaded relationships, calculations,
  and aggregates — relationship-as-read reactivity means a reloaded
  relationship with unchanged attributes must still invalidate the slots
  that read it. A field that is `%Ash.NotLoaded{}` on both sides is
  unchanged; loaded on one side only is changed (the truth moved or is
  unknown — invalidate).
  """

  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Table

  @doc "Changed field names between two records of the same resource."
  @spec diff(struct(), struct()) :: %{fields: [atom()]}
  def diff(%resource{} = old, %resource{} = new) do
    fields =
      resource
      |> field_names()
      |> Enum.filter(fn name ->
        field_changed?(Map.get(old, name), Map.get(new, name))
      end)

    %{fields: fields}
  end

  @doc """
  The changed slot addresses between two records, straight from the
  propagation index — the gate the live host needs to build a
  differential render. `:all` when the before-image is missing or the
  resources differ.
  """
  @spec changed_addresses(module() | Table.t(), struct() | nil, struct()) :: :all | MapSet.t()
  def changed_addresses(resource_or_table, old_record, new_record)

  def changed_addresses(resource, old, new) when is_atom(resource),
    do: changed_addresses(Compiler.table(resource), old, new)

  def changed_addresses(%Table{}, nil, _new), do: :all

  def changed_addresses(%Table{} = table, %old_resource{} = old, %new_resource{} = new) do
    if old_resource == new_resource do
      # Only fields present in the compiled propagation index can invalidate a
      # render slot. Walking the resource schema here is equivalent but turns
      # exact keyed-child diffing into one Ash metadata lookup per entry.
      table.propagation_addresses
      |> Enum.reduce(nil, fn {field, addresses}, changed ->
        if field_changed?(Map.get(old, field), Map.get(new, field)) do
          if changed, do: MapSet.union(changed, addresses), else: addresses
        else
          changed
        end
      end)
      |> then(&(&1 || MapSet.new()))
    else
      :all
    end
  end

  @doc false
  @spec changed_addresses_for_paths(Table.t(), [[atom()]]) :: MapSet.t()
  def changed_addresses_for_paths(%Table{} = table, paths) when is_list(paths) do
    paths = Enum.filter(paths, &match?([field | _rest] when is_atom(field), &1))

    table
    |> Table.root_slots()
    |> Enum.flat_map(fn {_id, slot} ->
      dep_paths = get_in(slot, [:meta, :dep_paths]) || Enum.map(slot.deps, &[&1])

      if Enum.any?(dep_paths, fn dep_path ->
           Enum.any?(paths, &path_related?(dep_path, &1))
         end) do
        owner = Map.get(slot.meta, :owner_addr, slot.addr)

        addresses = if owner == slot.addr, do: [slot.addr], else: [owner, slot.addr]

        if fragment_only_child_change?(slot, paths) do
          [{:fragment_inputs, slot.addr} | addresses]
        else
          addresses
        end
      else
        []
      end
    end)
    |> MapSet.new()
  end

  defp path_related?(left, right),
    do: prefix?(left, right) or prefix?(right, left)

  defp prefix?(prefix, path),
    do: Enum.take(path, length(prefix)) == prefix

  defp fragment_only_child_change?(%{kind: :child, meta: meta}, paths) do
    fragment_paths = Map.get(meta, :fragment_dep_paths, [])
    scalar_paths = Map.get(meta, :scalar_dep_paths, [])

    related_to_any?(fragment_paths, paths) and not related_to_any?(scalar_paths, paths)
  end

  defp fragment_only_child_change?(_slot, _paths), do: false

  defp related_to_any?(dep_paths, paths) do
    Enum.any?(dep_paths, fn dep_path ->
      Enum.any?(paths, &path_related?(dep_path, &1))
    end)
  end

  # ── fields ─────────────────────────────────────────────────────────────────

  defp field_names(resource) do
    attributes = resource |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)
    relationships = resource |> Ash.Resource.Info.relationships() |> Enum.map(& &1.name)
    calculations = resource |> Ash.Resource.Info.calculations() |> Enum.map(& &1.name)
    aggregates = resource |> Ash.Resource.Info.aggregates() |> Enum.map(& &1.name)

    attributes ++ relationships ++ calculations ++ aggregates
  end

  defp field_changed?(%Ash.NotLoaded{}, %Ash.NotLoaded{}), do: false
  defp field_changed?(%Ash.NotLoaded{}, _new), do: true
  defp field_changed?(_old, %Ash.NotLoaded{}), do: true
  defp field_changed?(old, new), do: old != new
end
