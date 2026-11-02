defmodule AshUi.DefectClass.DC13ClosedVocabularyTest do
  use ExUnit.Case, async: false
  alias AshUi.StaticCompile

  defmodule NativeCollectionPage do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    ash_ui do
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:entries, {:array, :map}, default: [])
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:entries, [], [
            each(entries, :entry, [key: :id], [
              paragraph(:entry_label, [], [
                text(entry.label)
              ])
            ])
          ])
        )
      )
    end
  end

  test "native constructors replace the deleted core collection vocabulary" do
    view = StaticCompile.compile!(NativeCollectionPage).view
    refute contains_kind?(view, :vocabulary)
    assert count_term(view, {:_ref, [], :entries}) == 1
    assert count_term(view, {:_item, :entry, [:label]}) == 1
  end

  test "vocabulary map nodes are rejected by static view compilation" do
    error =
      assert_raise Spark.Error.DslError, fn ->
        compile_page!(
          "VocabularyNodePage",
          """
          calculations do
            calculate(
              :view,
              AshUi.Type.RenderTree,
              expr(%{
                kind: :vocabulary,
                vocabulary: SomeVocabulary,
                node: :collection,
                name: :entries,
                options: %{items: entries},
                children: []
              })
            )
          end
          """
        )
      end

    assert Exception.message(error) =~ "view"
    assert Exception.message(error) =~ "unsupported view node"
  end

  test "ash_ui vocabularies config is rejected" do
    module = unique_module("VocabularyConfigPage")
    source = "defmodule #{inspect(module)} do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshUi],
    validate_domain_inclusion?: false

  ets do
    private?(true)
  end

  ash_ui do
    vocabularies [SomeVocabulary]
  end

  #{explicit_session_contract()}
end
"

    error = assert_raise ArgumentError, fn -> Code.compile_string(source) end
    assert Exception.message(error) =~ "unsupported ash_ui config entry"
    assert Exception.message(error) =~ "vocabularies"
  end

  defp compile_page!(name, view_source) do
    module = unique_module(name)
    source = "defmodule #{inspect(module)} do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshUi],
    validate_domain_inclusion?: false

  ets do
    private?(true)
  end

  ash_ui do
  end

  #{explicit_session_contract()}

  attributes do
    attribute :entries, {:array, :map}, default: []
  end

  #{view_source}
end
"
    Code.compile_string(source)
  end

  defp explicit_session_contract do
    """
    attributes do
      attribute :session_id, :uuid, allow_nil?: false, primary_key?: true
    end

    identities do
      identity :session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback
    end
    """
  end

  defp unique_module(name) do
    Module.concat([__MODULE__, String.to_atom("#{name}#{System.unique_integer([:positive])}")])
  end

  defp contains_kind?(%{kind: kind}, kind), do: true

  defp contains_kind?(%{} = map, kind) do
    map |> Map.values() |> Enum.any?(&contains_kind?(&1, kind))
  end

  defp contains_kind?(list, kind) when is_list(list) do
    Enum.any?(list, &contains_kind?(&1, kind))
  end

  defp contains_kind?(_term, _kind), do: false

  defp count_term(term, target) when term == target, do: 1

  defp count_term(%{} = map, target) do
    map |> Map.values() |> Enum.map(&count_term(&1, target)) |> Enum.sum()
  end

  defp count_term(tuple, target) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&count_term(&1, target)) |> Enum.sum()
  end

  defp count_term(list, target) when is_list(list) do
    list |> Enum.map(&count_term(&1, target)) |> Enum.sum()
  end

  defp count_term(_term, _target), do: 0
end
