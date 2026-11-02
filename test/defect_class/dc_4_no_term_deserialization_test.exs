defmodule AshUi.DefectClass.DC4NoTermDeserializationTest do
  use ExUnit.Case, async: false
  import AshUi.ViewConstructor
  alias AshUi.EventBinding
  @repo_root Path.expand("../..", __DIR__)
  @term_decode_pattern ~r/\b(?:Ash.Helpers.)?non_executable_binary_to_term\b|\bbinary_to_term\b/
  # Compiler output in ebin has the same executable trust boundary as BEAM.
  # No request, token, or application-authored channel reaches this decoder.
  @term_decode_allowlist [
    {"packages/ash_ui_phoenix/lib/ash_ui/phoenix/patch_artifact.ex", :decode}
  ]
  defmodule TogglePage do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

    ets do
      private?(true)
    end

    ash_ui do
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:visible?, :boolean, public?: true, default: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      update(:hide) do
        change(set_attribute(:visible?, false))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:stack, [], [
            if visible? do
              button(:hide_button, [type: :button, on_click: :hide], [text("Hide")])
            else
              nothing()
            end
          ])
        )
      )
    end
  end

  test "no production channel decodes terms" do
    hits =
      ["lib/**/*.ex", "packages/**/*.ex", "assets/**/*.js"]
      |> Enum.flat_map(&Path.wildcard(Path.join(@repo_root, &1)))
      |> Enum.reject(&String.contains?(&1, "/deps/"))
      |> Enum.flat_map(fn path ->
        source = File.read!(path)
        relative = Path.relative_to(path, @repo_root)

        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_no} -> line =~ @term_decode_pattern end)
        |> Enum.map(fn {line, line_no} ->
          {relative, enclosing_function(source, line_no), line_no, String.trim(line)}
        end)
      end)

    assert Enum.map(hits, fn {file, function, _line_no, _line} -> {file, function} end) ==
             @term_decode_allowlist
  end

  test "token-borne sessions have no Session decode path" do
    # the adapter (the only token channel) is deleted with the second model
    refute File.exists?(Path.join(@repo_root, "lib/ash_ui/adapter.ex"))
    refute Code.ensure_loaded?(AshUi.Adapter)
  end

  test "garbage binding keys miss the resolver cleanly" do
    record = Ash.Seed.seed!(TogglePage, %{session_id: Ash.UUID.generate(), visible?: true})
    assert AshUi.Patch.Bindings.resolve(record, "not-a-real.binding") == :error
    assert AshUi.Patch.Bindings.resolve(record, "") == :error
  end

  test "stale keys from a switched-off branch arm are not accepted" do
    record = Ash.Seed.seed!(TogglePage, %{session_id: Ash.UUID.generate(), visible?: true})

    table = AshUi.Patch.Compiler.table(TogglePage)

    {addr, _entry} =
      Enum.find(table.event_elements, fn {_a, e} -> Map.get(e, :conditions, []) != [] end)

    key = AshUi.Patch.Compiler.addr_component(addr) <> ".click"

    assert {:ok, %EventBinding{ui_event: :hide}, {:root}} =
             AshUi.Patch.Bindings.resolve(record, key)

    updated =
      record
      |> Ash.Changeset.for_update(:hide, %{},
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )
      |> Ash.update!(domain: AshUi.AshDomainFallback)

    assert updated.visible? == false

    # same key against the NEW record: the arm is off, the target is stale
    assert AshUi.Patch.Bindings.resolve(updated, key) == :error
  end

  defp enclosing_function(source, line_no) do
    source
    |> String.split("\n")
    |> Enum.take(line_no)
    |> Enum.reduce(nil, fn line, current ->
      case Regex.run(~r/^\s*defp?\s+([a-zA-Z_][a-zA-Z0-9_?!]*)\b/, line) do
        [_full, function] -> String.to_atom(function)
        _other -> current
      end
    end)
  end
end
