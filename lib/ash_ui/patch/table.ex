defmodule AshUi.Patch.Table do
  @moduledoc """
  Compiled patch table for one resource view: every dynamic position in the
  lowered view becomes a slot with a stable address, an evaluator, and the
  dependency field paths that invalidate it; the propagation index inverts
  dependencies to slot ids. Nested `render(Resource, input)` compiles the
  child resource's own table under an address prefix.

  This is compile-derived data (internals of the compiled artifact), not
  model vocabulary: the view stays an Ash calculation; this table is its
  partial evaluation staged for change-driven patch emission.
  """

  defstruct resource: nil,
            view: :view,
            target: AshUi.RenderTarget.Static,
            slots: %{},
            root_slot_ids: nil,
            propagation: %{},
            propagation_addresses: %{},
            collection_slots: %{},
            error_slots: [],
            children: %{},
            skeleton: nil,
            event_elements: %{},
            root: nil

  @type slot :: %{
          id: term(),
          addr: String.t(),
          kind: :text | :attrs | :branch | :keyed_list | :child,
          deps: [atom()],
          eval: (AshUi.Expr.Scope.t() -> term()),
          meta: map()
        }

  @type t :: %__MODULE__{
          resource: module() | nil,
          view: atom(),
          target: module(),
          slots: %{term() => slot()},
          root_slot_ids: [term()] | nil,
          propagation: %{atom() => [term()]},
          propagation_addresses: %{atom() => MapSet.t(String.t())},
          collection_slots: %{atom() => [term()]},
          children: %{String.t() => t()},
          skeleton: AshUi.Patch.Skeleton.t() | nil,
          event_elements: %{String.t() => map()},
          root: term()
        }

  @doc false
  def root_slots(%__MODULE__{slots: slots, root_slot_ids: nil}), do: slots

  def root_slots(%__MODULE__{slots: slots, root_slot_ids: ids}),
    do: Map.take(slots, ids)

  @doc false
  def item_slots(%__MODULE__{} = table, %{meta: %{item_slot_ids: ids}}) when is_list(ids),
    do: Map.take(table.slots, ids)

  # Tables persisted by resources compiled before the flattened slot-store
  # representation remain readable during rolling recompiles.
  def item_slots(%__MODULE__{}, %{meta: %{item_slots: slots}}) when is_map(slots), do: slots
  def item_slots(%__MODULE__{}, _slot), do: %{}
end
