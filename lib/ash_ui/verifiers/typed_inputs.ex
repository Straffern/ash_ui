defmodule AshUi.Verifiers.TypedInputs do
  @moduledoc false

  # Public attributes and calculations on AshUi resources must be
  # typed: :map / {:array, :map} / :term are the untyped-view-input
  # defect class — model the shape as an
  # embedded value resource with calculations for derived fields.
  # Escape hatch for genuinely opaque runtime handles: a description
  # containing "[opaque]" with a rationale.

  use Spark.Dsl.Verifier

  alias AshUi.Verifiers.Helpers
  alias Spark.Dsl.Transformer

  @untyped [:map, :term, Ash.Type.Map, Ash.Type.Term]

  @impl true
  def verify(dsl_state) do
    fields =
      Transformer.get_entities(dsl_state, [:attributes]) ++
        Transformer.get_entities(dsl_state, [:calculations])

    fields
    |> Enum.filter(&public_untyped?/1)
    |> case do
      [] ->
        :ok

      [field | _rest] ->
        raise Helpers.dsl_error(
                dsl_state,
                [:attributes, field.name],
                "public #{inspect(field.name)} is untyped (#{inspect(field_type(field))}) — " <>
                  "model the shape as an embedded value resource (typed attributes + " <>
                  "calculations for derived fields). For a genuinely opaque runtime " <>
                  "handle, add \"[opaque] <rationale>\" to its description."
              )
    end
  end

  defp public_untyped?(field) do
    Map.get(field, :public?, false) and untyped?(field_type(field)) and
      not opaque?(Map.get(field, :description))
  end

  defp field_type(field), do: Map.get(field, :type)

  defp untyped?({:array, inner}), do: untyped?(inner)
  defp untyped?(type), do: type in @untyped

  defp opaque?(description) when is_binary(description), do: description =~ "[opaque]"
  defp opaque?(_description), do: false
end
