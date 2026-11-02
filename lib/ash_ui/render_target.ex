defmodule AshUi.RenderTarget do
  @moduledoc """
  Adapter seam for lowering AshUi's neutral render protocol to a host target.
  """

  @callback attr_name(String.t()) :: String.t()
  @callback finalize_attrs(map(), atom() | String.t() | nil, map(), list()) :: map()
  @callback finalize_tree(term()) :: term()
  @callback finalize_skeleton_attrs(map()) :: map()
  @callback finalize_materialized_attrs(map()) :: map()
  @callback preserve_component_boundaries?() :: boolean()
  @callback runtime_chain_attrs?() :: boolean()
  @callback dispatch_event_value(String.t()) :: String.t()
  @callback compiled_table(module(), atom()) :: AshUi.Patch.Table.t() | nil

  @optional_callbacks dispatch_event_value: 1,
                      compiled_table: 2,
                      finalize_skeleton_attrs: 1,
                      finalize_materialized_attrs: 1,
                      preserve_component_boundaries?: 0,
                      runtime_chain_attrs?: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour AshUi.RenderTarget

      @impl AshUi.RenderTarget
      def dispatch_event_value(binding_key),
        do: "ash_ui:dispatch:" <> binding_key

      @impl AshUi.RenderTarget
      def finalize_attrs(attrs, _tag, _meta, _events), do: attrs

      defoverridable dispatch_event_value: 1, finalize_attrs: 4
    end
  end
end
