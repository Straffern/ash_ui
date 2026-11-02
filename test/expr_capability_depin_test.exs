defmodule AshUi.ExprCapabilityDepinTest do
  use ExUnit.Case, async: true

  defmodule Page do
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
      attribute(:slug, :string, default: "")
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      update(:save) do
        argument(:schema_slug, :string, allow_nil?: true)
        change(set_attribute(:slug, arg(:schema_slug)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          form(
            :editor,
            [
              action_input: %{
                schema_slug: path(event(:params), ["schema_name"]) || slug || "untitled"
              },
              on_submit: :save
            ],
            [input(:slug_field, type: :text, name: "schema_name", value: slug)]
          )
        )
      )
    end
  end

  test "capability + state accessor expr compiles and persists markers, not pins" do
    blueprint = AshUi.compile!(Page)

    assert Enum.any?(walk_terms(blueprint), &(&1 == {:_ref, [], :slug})),
           "expected de-pinned {:_ref, [], :slug} marker in persisted IR"

    refute Enum.any?(walk_terms(blueprint), fn
             {:^, _, _} -> true
             _other -> false
           end),
           "no pinned forms may persist"
  end

  defp walk_collect(term, fun) do
    walk_collect(term, fun, [])
  end

  defp walk_collect(%_{} = struct, fun, acc) do
    acc = fun.(struct) ++ acc
    struct |> Map.from_struct() |> Map.values() |> Enum.reduce(acc, &walk_collect(&1, fun, &2))
  end

  defp walk_collect(map, fun, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {_k, v}, a -> walk_collect(v, fun, a) end)
  end

  defp walk_collect(list, fun, acc) when is_list(list) do
    Enum.reduce(list, acc, &walk_collect(&1, fun, &2))
  end

  defp walk_collect(tuple, fun, acc) when is_tuple(tuple) do
    acc = fun.(tuple) ++ acc
    tuple |> Tuple.to_list() |> Enum.reduce(acc, &walk_collect(&1, fun, &2))
  end

  defp walk_collect(other, fun, acc) do
    fun.(other) ++ acc
  end

  defp walk_terms(term) do
    walk_collect(term, &[&1])
  end
end
