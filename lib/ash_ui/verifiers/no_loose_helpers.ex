defmodule AshUi.Verifiers.NoLooseHelpers do
  @moduledoc false

  # AshUi resource modules define ZERO private helper functions:
  # behavior belongs in calculations, an action's inline implementation,
  # or an embedded-resource calculation. Escape hatch:
  # a `# helper: name/arity — <rationale>` comment on one of the two
  # lines directly above the defp, where the rationale must justify
  # multi-use or boundary-adapter status.
  #
  # The scan covers the module's own source span (defmodule line to its
  # closing `end` at the same indentation, per mix-format layout), so
  # sibling modules in the same file are not misattributed.

  use Spark.Dsl.Verifier

  alias AshUi.Verifiers.Helpers

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    with source when is_binary(source) <- module_source(module),
         lines = String.split(source, "\n"),
         {:ok, span} <- module_span(lines, module) do
      case violations(lines, span) do
        [] ->
          :ok

        [{line_no, signature} | _rest] ->
          raise Helpers.dsl_error(
                  dsl_state,
                  [:helpers],
                  "private helper `#{signature}` (line #{line_no}) in an AshUi resource — " <>
                    "model it as a calculation, an action's inline implementation, or an " <>
                    "embedded-resource calculation. If it is genuinely a multi-use boundary " <>
                    "mechanic, add `# helper: #{signature} — <rationale>` directly above it."
                )
      end
    else
      _no_source -> :ok
    end
  end

  defp module_source(module) do
    with info when is_list(info) <- module.__info__(:compile),
         source when is_list(source) <- Keyword.get(info, :source),
         path = List.to_string(source),
         {:ok, contents} <- File.read(path) do
      contents
    else
      _other -> nil
    end
  rescue
    # broad rescue: source may be unreadable (releases, in-memory
    # compiles) — the verifier then abstains rather than crashing
    # compilation.
    _exception -> nil
  end

  defp module_span(lines, module) do
    last_alias = module |> Module.split() |> List.last()
    pattern = ~r/^(\s*)defmodule\s.*#{Regex.escape(last_alias)}\s+do\b/

    lines
    |> Enum.with_index(1)
    |> Enum.find(fn {line, _index} -> Regex.match?(pattern, line) end)
    |> case do
      nil ->
        :error

      {line, start_index} ->
        [indent] = Regex.run(~r/^(\s*)/, line, capture: :all_but_first)
        closing = ~r/^#{indent}end\s*$/

        stop_index =
          lines
          |> Enum.with_index(1)
          |> Enum.find_value(length(lines), fn {candidate, index} ->
            if index > start_index and Regex.match?(closing, candidate), do: index
          end)

        {:ok, {start_index, stop_index}}
    end
  end

  defp violations(lines, {start_index, stop_index}) do
    indexed = Enum.with_index(lines, 1)

    for {line, index} <- indexed,
        index > start_index and index < stop_index,
        captures = Regex.run(~r/^\s*defp\s+([a-zA-Z0-9_?!]+)\s*(?:\(([^)]*)\))?/, line),
        not rationale_above?(lines, index) do
      [_, name | rest] = captures

      arity =
        case rest do
          [args] when args != "" -> args |> String.split(",") |> length()
          _other -> 0
        end

      {index, "#{name}/#{arity}"}
    end
  end

  defp rationale_above?(lines, index) do
    lines
    |> Enum.slice(max(index - 3, 0), 2)
    |> Enum.any?(&String.match?(&1, ~r/#\s*helper:/))
  end
end
