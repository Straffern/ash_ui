defmodule AshUi.DefectClass.DC18HostBoundaryTest do
  use ExUnit.Case, async: false
  @lib_root Path.expand("../../lib", __DIR__)
  test "DC-18 core library remains host-neutral" do
    source = lib_source()

    refute Regex.match?(~r/phx|live_view|LiveView|Phoenix/, source)
  end

  test "DC-18 adapter token owner and table sources stay deleted from core" do
    source = lib_source()
    refute source =~ ":ash_ui_adapter_tokens"
    refute source =~ "ensure_token_owner"
  end

  # The render-algebra kernel (rendered.ex, diff.ex, render.ex) is the ONE
  # sanctioned LiveView-compatibility surface: its documentation must name
  # the wire protocol and the test oracle. Compatibility-by-contract is not
  # runtime coupling — no Phoenix module is referenced as code anywhere in
  # core, which the process-free-core test asserts module-by-module.
  @kernel_files ~w(rendered.ex diff.ex render.ex)

  defp lib_source do
    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) in @kernel_files and kernel_path?(&1)))
    |> Enum.map_join("\n", &File.read!/1)
  end

  defp kernel_path?(path), do: String.ends_with?(Path.dirname(path), "lib/ash_ui")
end
