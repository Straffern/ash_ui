defmodule AshUi.ProcessFreeCoreTest do
  use ExUnit.Case, async: true
  @repo_root Path.expand("..", __DIR__)
  @forbidden_patterns [
    ~r"mod: *{AshUi.Application",
    ~r"use +Application",
    ~r"use +GenServer",
    ~r"use +Agent",
    ~r"use +Supervisor",
    ~r"use +DynamicSupervisor",
    ~r"Registry.child_spec",
    ~r"Task.Supervisor",
    ~r"Task.async",
    ~r"Task.start",
    ~r"Process.(put|get)",
    ~r"Supervisor.start_link",
    ~r"GenServer.start_link",
    ~r":persistent_term",
    ~r":ets.(new|insert|insert_new|lookup|delete)"
  ]
  @forbidden_framework_refs ["AshAuthentication.Phoenix", "AshPhoenix", "Phoenix", "Plug"]
  # The notification substrate is the ONE sanctioned process boundary:
  # the 2026-07-09 audit required supervision (keyed ETS index owner,
  # session-pid monitors, session-row GC). Everything else stays
  # process-free.
  @allowed_process_boundary_refs [
    {"lib/ash_ui/compiled.ex", ~r":persistent_term"},
    {"mix.exs", ~r"mod: *{AshUi.Application"},
    {"lib/ash_ui/application.ex", ~r"use +Application"},
    {"lib/ash_ui/application.ex", ~r"Supervisor.start_link"},
    {"lib/ash_ui/notification/match_index.ex", ~r"use +GenServer"},
    {"lib/ash_ui/notification/match_index.ex", ~r"GenServer.start_link"},
    {"lib/ash_ui/notification/match_index.ex",
     ~r":ets.(new|insert|insert_new|lookup|delete)"},
    {"lib/ash_ui/notification/session_registry.ex", ~r"use +GenServer"},
    {"lib/ash_ui/notification/session_registry.ex", ~r"GenServer.start_link"}
  ]
  test "core does not define an application runtime, process owner, or global cache" do
    files =
      ["mix.exs" | Path.wildcard(Path.join(@repo_root, "lib/**/*.ex"))]
      |> Enum.map(&Path.relative_to(&1, @repo_root))
      |> Enum.reject(&String.contains?(&1, "/ash/resource/"))

    violations =
      for file <- files,
          source = File.read!(Path.join(@repo_root, file)),
          pattern <- @forbidden_patterns,
          Regex.match?(pattern, source),
          not allowed_process_boundary_ref?(file, pattern) do
        {file, inspect(pattern)}
      end

    assert violations == []
  end

  # The render-algebra kernel documents its LiveView wire-protocol
  # compatibility and test oracle by name — documentation, not coupling.
  # Code references stay forbidden: strip comments/docs before scanning.
  @kernel_files [
    "lib/ash_ui/rendered.ex",
    "lib/ash_ui/diff.ex",
    "lib/ash_ui/render.ex"
  ]

  test "core does not reference adapter framework modules" do
    violations =
      core_files()
      |> Enum.flat_map(fn file ->
        source = File.read!(Path.join(@repo_root, file))

        source =
          if file in @kernel_files do
            source
            |> String.split("\n")
            |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("#")))
            |> Enum.join("\n")
            |> String.replace(~r/@(module)?doc \"\"\".*?\"\"\"/s, "")
          else
            source
          end

        @forbidden_framework_refs
        |> Enum.filter(&String.contains?(source, &1))
        |> Enum.map(&{file, &1})
      end)

    assert violations == []
  end

  defp core_files do
    ["mix.exs" | Path.wildcard(Path.join(@repo_root, "lib/**/*.ex"))]
    |> Enum.map(&Path.relative_to(&1, @repo_root))
    |> Enum.reject(&String.contains?(&1, "/ash/resource/"))
  end

  defp allowed_process_boundary_ref?(file, pattern) do
    Enum.any?(@allowed_process_boundary_refs, fn {allowed_file, allowed_pattern} ->
      file == allowed_file and inspect(pattern) == inspect(allowed_pattern)
    end)
  end
end
