defmodule AshUi.StaticCompilePipelineTest do
  use ExUnit.Case, async: false
  import AshUi.ViewConstructor

  defmodule ArtistDirectory do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule PersistedPage do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

    ets do
      private?(true)
    end

    ash_ui do
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:query, :string, default: "")
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many(:artists, ArtistDirectory) do
        no_attributes?(true)
        read_action(:read)
        filter(expr(name == parent(query)))
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(box(:stack, [], [text("artists")])))
    end
  end

  test "compiled accessors return persisted compile artifacts without injected helpers" do
    calls =
      trace_calls(
        [{AshUi.StaticCompile, :snapshot!, 1}],
        fn ->
          refute function_exported?(PersistedPage, :compiled_resource, 0)
          refute function_exported?(PersistedPage, :compiled_blueprint, 0)
          refute function_exported?(PersistedPage, :new, 1)
          refute function_exported?(PersistedPage, :run_read, 4)

          assert %AshUi.ResourceBlueprint{} =
                   AshUi.Compiled.resource!(PersistedPage)

          assert is_map(AshUi.Compiled.blueprint!(PersistedPage))

          assert %AshUi.ResourceBlueprint{} =
                   AshUi.Compiled.resource!(PersistedPage)

          assert is_map(AshUi.Compiled.blueprint!(PersistedPage))
        end
      )

    assert calls == []
  end

  test "static compile loads source resource shape without parsing the source file" do
    calls =
      trace_calls(
        [{File, :read, 1}, {Code, :string_to_quoted, 2}],
        fn ->
          definition = AshUi.StaticCompile.resource_definition!(PersistedPage)
          resource = AshUi.StaticCompile.compile!(PersistedPage)
          [relationship] = definition.relationships
          assert resource.view != nil
          assert relationship.destination == ArtistDirectory
          assert relationship.read_action == :read
        end
      )

    assert calls == []
  end

  test "compiled accessors use persisted normalized contracts without rerunning static compilation" do
    calls =
      trace_calls(
        [{AshUi.StaticCompile, :snapshot!, 1}, {AshUi.StaticCompile, :compile!, 1}],
        fn ->
          assert %AshUi.ResourceBlueprint{} =
                   AshUi.Compiled.resource!(PersistedPage)

          assert is_map(AshUi.Compiled.blueprint!(PersistedPage))
        end
      )

    assert calls == []
  end

  defp trace_calls(mfas, fun) do
    Enum.each(mfas, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(self(), true, [:call])

    try do
      fun.()
      drain_traces()
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(mfas, &:erlang.trace_pattern(&1, false, [:local]))
    end
  end

  defp drain_traces(acc \\ []) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        drain_traces([{module, function, length(args)} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
