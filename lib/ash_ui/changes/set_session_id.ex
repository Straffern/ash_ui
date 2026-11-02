defmodule AshUi.Changes.SetSessionId do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, action_context) do
    context = merge_context(changeset.context || %{}, action_context)
    session = blueprint_session(context) || map_get(context, :session) || %{}

    maybe_force_session_id(
      changeset,
      first_present([
        map_get(context, :session_id),
        map_get(context, "session_id"),
        map_get(session, :session_id),
        map_get(session, "session_id"),
        map_get(session, :id),
        map_get(session, "id"),
        changed_attribute(changeset, :session_id),
        map_get(changeset.data, :session_id)
      ])
    )
  end

  defp maybe_force_session_id(changeset, value) when is_binary(value) and value != "" do
    if has_attribute?(changeset.resource, :session_id) do
      changeset
      |> Ash.Changeset.force_change_attribute(:session_id, value)
      |> Ash.Changeset.after_action(fn _changeset, record ->
        # Crash-path row GC follows the adapter-owned session process. An
        # external Ash caller can reuse that ownership, never replace it.
        AshUi.Notification.MatchIndex.track_session_rows(
          changeset.resource,
          value,
          get_in(changeset.context, [:shared, :ash_ui_session_pid]) ||
            Map.get(changeset.context, :ash_ui_session_pid),
          changeset.tenant
        )

        {:ok, record}
      end)
    else
      changeset
    end
  end

  defp maybe_force_session_id(changeset, _value), do: changeset

  defp has_attribute?(resource, name) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.any?(&(&1.name == name))
  end

  defp changed_attribute(changeset, name), do: Map.get(changeset.attributes || %{}, name)

  defp blueprint_session(context) when is_map(context) do
    case get_in(context, [:ash_ui, :session]) do
      session when is_map(session) -> session
      _other -> nil
    end
  end

  defp blueprint_session(_context), do: nil

  defp merge_context(left, right) when is_map(right) do
    right = change_source_context(right)

    Map.merge(left || %{}, right, fn
      :ash_ui, left_value, right_value when is_map(left_value) and is_map(right_value) ->
        Map.merge(left_value, right_value)

      _key, _left_value, right_value ->
        right_value
    end)
  end

  defp merge_context(left, _right), do: left || %{}

  defp change_source_context(%{
         __struct__: Ash.Resource.Change.Context,
         source_context: source_context
       })
       when is_map(source_context) do
    source_context
  end

  defp change_source_context(context), do: context

  defp first_present(values) do
    Enum.find(values, fn
      value when is_binary(value) -> value != ""
      nil -> false
      _value -> true
    end)
  end

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)
  defp map_get(_map, _key), do: nil
end
