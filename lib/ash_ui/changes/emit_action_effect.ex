defmodule AshUi.Changes.EmitActionEffect do
  @moduledoc false

  use Ash.Resource.Change

  @effects [:focus, :scroll_into_view, :select_text]
  @scroll_positions [:start, :center, :end, :nearest]
  @scroll_behaviors [:auto, :smooth, :instant]

  @impl true
  def init(opts) do
    with {:ok, effect} <- fetch_member(opts, :effect, @effects),
         :ok <- validate_option_keys(opts, effect),
         {:ok, target} <- target(opts),
         {:ok, when_arguments} <- when_arguments(opts),
         {:ok, options} <- effect_options(effect, opts) do
      {:ok,
       [
         effect: %AshUi.ActionEffect{
           name: effect,
           target: target,
           options: options
         },
         when_arguments: when_arguments
       ]}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    if emit_for_arguments?(changeset, opts[:when_arguments]) do
      Ash.Changeset.after_action(changeset, fn changeset, record ->
        context = changeset.context || %{}

        with pid when is_pid(pid) <- context_value(context, :ash_ui_action_effect_pid),
             ref when is_reference(ref) <-
               context_value(context, :ash_ui_action_effect_ref) do
          send(pid, {:ash_ui_action_effect, ref, opts[:effect]})
        end

        {:ok, record}
      end)
    else
      changeset
    end
  end

  defp target(opts) do
    case {Keyword.get(opts, :id), Keyword.get(opts, :part)} do
      {id, nil} when is_binary(id) and id != "" -> {:ok, {:id, id}}
      {nil, nil} -> {:error, "one of :id or :part is required"}
      {nil, part} when is_atom(part) -> {:ok, {:part, Atom.to_string(part)}}
      {nil, part} when is_binary(part) and part != "" -> {:ok, {:part, part}}
      _other -> {:error, "exactly one non-empty :id or :part target is required"}
    end
  end

  defp when_arguments(opts) do
    arguments = List.wrap(Keyword.get(opts, :when_arguments, []))

    if Enum.all?(arguments, &is_atom/1) do
      {:ok, arguments}
    else
      {:error, ":when_arguments must contain only argument names"}
    end
  end

  defp effect_options(:scroll_into_view, opts) do
    with {:ok, block} <- optional_member(opts, :block, @scroll_positions, :nearest),
         {:ok, inline} <- optional_member(opts, :inline, @scroll_positions, :nearest),
         {:ok, behavior} <- optional_member(opts, :behavior, @scroll_behaviors, :auto) do
      {:ok, %{options: %{block: block, inline: inline, behavior: behavior}}}
    end
  end

  defp effect_options(:focus, opts) do
    case Keyword.get(opts, :prevent_scroll, true) do
      value when is_boolean(value) -> {:ok, %{prevent_scroll: value}}
      _other -> {:error, ":prevent_scroll must be a boolean"}
    end
  end

  defp effect_options(:select_text, _opts), do: {:ok, %{}}

  defp validate_option_keys(opts, effect) do
    effect_keys =
      case effect do
        :scroll_into_view -> [:block, :inline, :behavior]
        :focus -> [:prevent_scroll]
        :select_text -> []
      end

    allowed = [:effect, :id, :part, :when_arguments | effect_keys]

    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> {:error, "undeclared action effect options: #{inspect(Enum.uniq(unknown))}"}
    end
  end

  defp fetch_member(opts, key, members) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if value in members do
          {:ok, value}
        else
          {:error, "#{inspect(key)} must be one of #{inspect(members)}, got: #{inspect(value)}"}
        end

      :error ->
        {:error, "#{inspect(key)} is required"}
    end
  end

  defp optional_member(opts, key, members, default) do
    value = Keyword.get(opts, key, default)

    if value in members do
      {:ok, value}
    else
      {:error, "#{inspect(key)} must be one of #{inspect(members)}, got: #{inspect(value)}"}
    end
  end

  defp emit_for_arguments?(_changeset, []), do: true

  defp emit_for_arguments?(changeset, argument_names) do
    Enum.any?(argument_names, fn name -> present?(Ash.Changeset.get_argument(changeset, name)) end)
  end

  defp present?(value) when value in [nil, "", [], %{}], do: false
  defp present?(_value), do: true

  defp context_value(context, key) do
    Map.get(context, key) || get_in(context, [:shared, key])
  end
end
