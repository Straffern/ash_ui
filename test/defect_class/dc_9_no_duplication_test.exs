defmodule AshUi.DefectClass.DC9NoDuplicationTest do
  use ExUnit.Case, async: true
  @runtime_dir Path.expand("../../lib/ash_ui/runtime", __DIR__)
  test "route casting is deleted with the second model — mount action typing owns casts" do
    refute Code.ensure_loaded?(AshUi.Runtime.RouteCast)
    assert definition_modules(~r/^\s*defp?\s+cast_route_/m, runtime_paths()) == []
  end

  test "variant score and match helpers are deleted with the second model" do
    refute Code.ensure_loaded?(AshUi.Runtime.Variants)
    assert definition_modules(~r/^\s*defp?\s+variants_match\?/m, runtime_paths()) == []
    assert definition_modules(~r/^\s*defp?\s+variant_match_score\b/m, runtime_paths()) == []
  end

  test "render_view_node dispatch is defined in exactly one module" do
    assert definition_modules(~r/^\s*defp?\s+render_view_node\b/m, runtime_paths()) == [
             AshUi.Runtime.ViewRender
           ]
  end

  defp runtime_paths do
    @runtime_dir |> Path.join("*.ex") |> Path.wildcard()
  end

  defp definition_modules(pattern, paths) do
    paths
    |> Enum.filter(fn path -> File.read!(path) =~ pattern end)
    |> Enum.map(&module_name!/1)
    |> Enum.sort()
  end

  defp module_name!(path) do
    [_, module] =
      Regex.run(
        ~r/defmodule\s+([A-Za-z0-9_.]+)/,
        File.read!(path)
      )

    String.to_existing_atom("Elixir." <> module)
  end
end
