defmodule AshUi.Patch.Keys do
  @moduledoc """
  THE entry-key function for keyed collections — one identity rule shared
  by the live renderer and the binding resolver, implementing Ash resource
  identity correctly:

  1. an authored `key:` expression wins when declared;
  2. an Ash resource keys on its FULL primary key — a composite key is the
     tuple of its values (first-field-only keying collides);
  3. plain maps fall back to `:id`/`"id"`, then ordinal position.
  """

  @doc "Entry key for `item` at ordinal `index`, honoring `key_eval` when present."
  @spec entry_key(term(), non_neg_integer(), AshUi.Patch.Evaluator.t() | nil, term()) ::
          term()
  def entry_key(item, index, key_eval \\ nil, scope \\ nil)

  def entry_key(_item, _index, key_eval, scope) when not is_nil(key_eval) and not is_nil(scope) do
    AshUi.Patch.Evaluator.eval(key_eval, scope)
  end

  def entry_key(%resource{} = item, index, _key_eval, _scope) do
    if Ash.Resource.Info.resource?(resource) do
      case Ash.Resource.Info.primary_key(resource) do
        [] -> index
        [pk] -> Map.get(item, pk)
        composite -> composite |> Enum.map(&Map.get(item, &1)) |> List.to_tuple()
      end
    else
      Map.get(item, :id) || index
    end
  end

  def entry_key(item, index, _key_eval, _scope) when is_map(item),
    do: Map.get(item, :id) || Map.get(item, "id") || index

  def entry_key(_item, index, _key_eval, _scope), do: index
end
