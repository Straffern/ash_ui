defmodule AshUi.BenchDataLayer do
  @moduledoc false

  @switch "ASH_UI_BENCH_DATA_LAYER"
  @ash_ets_data_layer :"Elixir.AshEts.DataLayer"
  @ash_ets_enabled? System.get_env(@switch) == "ash_ets"

  def entity_data_layer?(Ash.DataLayer.Ets), do: true
  def entity_data_layer?(@ash_ets_data_layer), do: @ash_ets_enabled?
  def entity_data_layer?(_data_layer), do: false
end
