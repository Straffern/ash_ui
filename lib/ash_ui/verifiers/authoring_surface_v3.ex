defmodule AshUi.Verifiers.AuthoringSurfaceV3 do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Ash.Query.Call
  alias AshUi.EventBinding
  alias AshUi.Verifiers.Helpers
  alias Spark.Error.DslError

  @legacy_key :__ash_ui_legacy__

  @impl true
  def verify(dsl_state) do
    verify_blueprint_data_layer!(dsl_state)
    resource = Helpers.compiled_resource!(dsl_state)

    diagnostics =
      resource
      |> term_diagnostics()
      |> Enum.uniq_by(fn diagnostic ->
        {diagnostic.form, diagnostic.replacement, diagnostic.path, diagnostic.location}
      end)

    case diagnostics do
      [] ->
        :ok

      [diagnostic | _rest] ->
        raise dsl_error(dsl_state, diagnostic)
    end
  end

  # Entity UI state is stock ETS; value components are embedded. The exact-value
  # benchmark switch also admits AshEts without changing the default storage axis.
  defp verify_blueprint_data_layer!(dsl_state) do
    data_layer = Spark.Dsl.Verifier.get_persisted(dsl_state, :data_layer)
    embedded? = Spark.Dsl.Verifier.get_persisted(dsl_state, :embedded?, false)

    if AshUi.BenchDataLayer.entity_data_layer?(data_layer) or
         (embedded? and data_layer == Ash.DataLayer.Simple) do
      :ok
    else
      raise Helpers.dsl_error(
              dsl_state,
              [:resource],
              "AshUi resources must use `data_layer: Ash.DataLayer.Ets` for entity UI state " <>
                "or `data_layer: :embedded` for value components"
            )
    end
  end

  defp term_diagnostics(resource) do
    []
    |> collect_term(resource.view, [:view])
    |> collect_term(resource.actions, [:actions])
  end

  defp collect_term(acc, nil, _path), do: acc

  defp collect_term(acc, %EventBinding{} = binding, path) do
    acc
    |> collect_legacy_entries(binding.meta || %{}, path)
    |> collect_term(binding.args_exprs, path ++ [:args])
    |> collect_term(Map.get(binding.meta || %{}, :key_filter), path ++ [:when])
  end

  defp collect_term(acc, %Call{name: :get_path, args: args}, path) do
    acc
    |> prepend_diagnostic(:get_path, "path", path, [])
    |> collect_term(args, path ++ [:args])
  end

  defp collect_term(acc, %Call{args: args}, path) do
    collect_term(acc, args, path ++ [:args])
  end

  defp collect_term(acc, {:__ash_ui_legacy_expr__, legacy, expression}, path) do
    acc
    |> collect_legacy_entry(legacy, path)
    |> collect_term(expression, path ++ [:expr])
  end

  defp collect_term(acc, {:dom, _meta, [_name]} = tuple, path) do
    acc
    |> prepend_diagnostic(:dom, "payload", path, [])
    |> collect_tuple(tuple, path)
  end

  defp collect_term(acc, tuple, path) when is_tuple(tuple) do
    collect_tuple(acc, tuple, path)
  end

  defp collect_term(acc, list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {value, index}, next_acc ->
      collect_term(next_acc, value, path ++ [index])
    end)
  end

  defp collect_term(acc, %_{} = struct, path) do
    collect_term(acc, Map.from_struct(struct), path)
  end

  defp collect_term(acc, map, path) when is_map(map) do
    acc = collect_legacy_entries(acc, map, path)

    Enum.reduce(map, acc, fn
      {@legacy_key, _legacy}, next_acc ->
        next_acc

      {key, value}, next_acc ->
        next_acc
        |> collect_term(key, path ++ [:key])
        |> collect_term(value, path ++ [key])
    end)
  end

  defp collect_term(acc, _other, _path), do: acc

  defp collect_tuple(acc, tuple, path) do
    tuple
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {value, index}, next_acc ->
      collect_term(next_acc, value, path ++ [index])
    end)
  end

  defp collect_legacy_entries(acc, map, path) when is_map(map) do
    map
    |> Map.get(@legacy_key, [])
    |> List.wrap()
    |> Enum.reduce(acc, fn legacy, next_acc -> collect_legacy_entry(next_acc, legacy, path) end)
  end

  defp collect_legacy_entry(acc, %{form: form, replacement: replacement} = legacy, path) do
    [
      diagnostic(form, replacement, path, Map.get(legacy, :location, []))
      | acc
    ]
  end

  defp collect_legacy_entry(acc, _legacy, _path), do: acc

  defp prepend_diagnostic(acc, form, replacement, path, location) do
    [diagnostic(form, replacement, path, location) | acc]
  end

  defp diagnostic(form, replacement, path, location) do
    %{
      form: form,
      replacement: replacement,
      path: path,
      location: normalize_location(location)
    }
  end

  defp dsl_error(dsl_state, diagnostic) do
    opts = [
      module: Helpers.module!(dsl_state),
      path: List.wrap(diagnostic.path),
      message: legacy_message(diagnostic)
    ]

    opts =
      case dsl_error_location(diagnostic.location) do
        nil -> opts
        location -> Keyword.put(opts, :location, location)
      end

    DslError.exception(opts)
  end

  defp legacy_message(%{form: form, replacement: replacement}) do
    "AshUi DSL v3 deletes #{format_form(form)}; use #{replacement} instead."
  end

  defp format_form(form) when is_atom(form), do: Atom.to_string(form)
  defp format_form(form), do: inspect(form)

  defp normalize_location(location) when is_list(location) do
    location
    |> Keyword.take([:file, :line, :column])
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == :undefined end)
  end

  defp normalize_location(_location), do: []

  defp dsl_error_location(location) do
    file = Keyword.get(location, :file)
    line = Keyword.get(location, :line)

    cond do
      is_binary(file) and is_integer(line) ->
        :erl_anno.set_file(String.to_charlist(file), :erl_anno.new(line))

      is_integer(line) ->
        :erl_anno.new(line)

      true ->
        nil
    end
  end
end
