defmodule AshUi.Verifiers.StrictAfterVerify do
  @moduledoc false

  alias Spark.Error.DslError

  @verifiers [
    AshUi.Verifiers.AuthoringSurfaceV3,
    AshUi.Verifiers.ExplicitSessions,
    AshUi.Verifiers.NoLooseHelpers,
    AshUi.Verifiers.TypedInputs,
    AshUi.Verifiers.NoExprSetAttribute,
    AshUi.Verifiers.VerifyExpressions,
    AshUi.Verifiers.SurfaceContracts,
    AshUi.Verifiers.StylesheetResolution,
    AshUi.Verifiers.StylesheetCoverage
  ]

  @doc false
  def __after_compile__(%Macro.Env{module: module}, _bytecode) when is_atom(module) do
    dsl_state = module.spark_dsl_config()

    errors =
      @verifiers
      |> Enum.flat_map(&run_verifier(module, dsl_state, &1))
      |> Enum.uniq()

    case errors do
      [] ->
        :ok

      [%DslError{stacktrace: %{stacktrace: stacktrace}} = error] when not is_nil(stacktrace) ->
        reraise error, stacktrace

      [error] when is_exception(error) ->
        raise error

      errors ->
        raise DslError,
          module: module,
          path: [:ash_ui],
          message:
            "Multiple Errors Occurred\n\n" <>
              Enum.map_join(errors, "\n---\n", &format_error/1)
    end
  end

  defp run_verifier(module, dsl_state, verifier) do
    maybe_report_invocation(module, verifier)

    case verifier.verify(dsl_state) do
      :ok ->
        []

      {:warn, warnings} ->
        emit_warnings(warnings)
        []

      {:error, error} ->
        List.wrap(error)
    end

    # broad rescue: strict verifier boundary captures any verifier exception so it
    # can be reported through the same located DslError aggregation path.
  rescue
    error ->
      [error]
  end

  defp emit_warnings(warnings) do
    warnings
    |> List.wrap()
    |> Enum.each(fn
      {warning, location} -> Spark.Warning.warn(warning, location, [])
      warning -> Spark.Warning.warn(warning, nil, [])
    end)
  end

  defp maybe_report_invocation(module, verifier) do
    case Application.get_env(:ash_ui, :verifier_invocation_counter) do
      {pid, ref} when is_pid(pid) ->
        send(pid, {ref, :verifier_invoked, module, verifier})

      _other ->
        :ok
    end
  end

  defp format_error(%DslError{stacktrace: %{stacktrace: stacktrace}} = error)
       when not is_nil(stacktrace) do
    Exception.format(:error, error, stacktrace)
  end

  defp format_error(error) when is_exception(error) do
    {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
    Exception.format(:error, error, stacktrace)
  end

  defp format_error(error), do: inspect(error)
end
