defmodule AshUi.Verifiers.ExplicitSessions do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias AshUi.Verifiers.Helpers
  alias Spark.Dsl.Transformer

  @impl true
  def verify(dsl_state) do
    if entity_resource?(dsl_state) do
      with :ok <- reject_dunder_subject(dsl_state),
           :ok <- verify_session_attribute(dsl_state),
           :ok <- verify_session_identity(dsl_state) do
        :ok
      else
        {:error, error} -> raise error
      end
    else
      :ok
    end
  end

  defp entity_resource?(dsl_state) do
    data_layer = Spark.Dsl.Verifier.get_persisted(dsl_state, :data_layer)
    embedded? = Spark.Dsl.Verifier.get_persisted(dsl_state, :embedded?, false)

    AshUi.BenchDataLayer.entity_data_layer?(data_layer) and not embedded?
  end

  defp reject_dunder_subject(dsl_state) do
    legacy_subject = legacy_subject_attribute()

    cond do
      Enum.any?(attributes(dsl_state), &(&1.name == legacy_subject)) ->
        {:error,
         Helpers.dsl_error(
           dsl_state,
           [:attributes, legacy_subject],
           "legacy dunder subject is no longer part of AshUi identity. Declare natural subject attributes, then include them with `:session_id` in a session-scoped identity."
         )}

      Enum.any?(identities(dsl_state), fn identity ->
        legacy_subject in List.wrap(Map.get(identity, :keys, []))
      end) ->
        {:error,
         Helpers.dsl_error(
           dsl_state,
           [:identities],
           "legacy dunder subject is no longer part of AshUi identity. Use natural subject attributes in the session-scoped identity."
         )}

      true ->
        :ok
    end
  end

  defp verify_session_attribute(dsl_state) do
    case Enum.find(attributes(dsl_state), &(&1.name == :session_id)) do
      nil ->
        hint =
          case closest_attribute_name(dsl_state, :session_id) do
            nil -> ""
            name -> " Did you mean `#{name}`?"
          end

        {:error,
         Helpers.dsl_error(
           dsl_state,
           [:attributes],
           "AshUi entity resources must explicitly declare `attribute :session_id`.#{hint} The runtime populates this declared attribute from changeset context; AshUi no longer injects it."
         )}

      %{allow_nil?: true} ->
        {:error,
         Helpers.dsl_error(
           dsl_state,
           [:attributes, :session_id],
           "AshUi entity resources must declare `attribute :session_id` with `allow_nil?: false` (a session-scoped row cannot exist without its session). Add `allow_nil?: false` (or `primary_key?: true`, which implies it)."
         )}

      _attribute ->
        :ok
    end
  end

  defp verify_session_identity(dsl_state) do
    case Enum.find(identities(dsl_state), &(:session_id in List.wrap(Map.get(&1, :keys, [])))) do
      nil ->
        {:error,
         Helpers.dsl_error(
           dsl_state,
           [:identities],
           "AshUi entity resources must declare a session-scoped identity containing `:session_id`, for example `identity :session_instance, [:session_id]` or `identity :session_instance, [:session_id, :natural_subject]`."
         )}

      _identity ->
        :ok
    end
  end

  defp attributes(dsl_state), do: Transformer.get_entities(dsl_state, [:attributes])
  defp identities(dsl_state), do: Transformer.get_entities(dsl_state, [:identities])

  defp legacy_subject_attribute, do: String.to_atom("__" <> "subject__")

  defp closest_attribute_name(dsl_state, expected) do
    expected_string = Atom.to_string(expected)

    dsl_state
    |> attributes()
    |> Enum.map(& &1.name)
    |> Enum.find(fn name ->
      name
      |> Atom.to_string()
      |> String.jaro_distance(expected_string)
      |> Kernel.>(0.84)
    end)
  end
end
