defmodule AshUi.Phoenix.Bridge do
  @moduledoc """
  Compile-time contract for host-specific LiveView integration.

  A bridge supplies the transport session and route-local host options used
  while mounting an AshUi resource. This module validates the host
  implementation and exposes a session MFA suitable for a Phoenix
  `live_session`. It does not define UI structure or application state.
  """

  @callbacks [
    generate_session: 2,
    route_group: 1,
    route_options: 2,
    screen_action: 2
  ]

  @callback generate_session(Plug.Conn.t(), keyword()) :: map()
  @callback route_group(term()) :: map() | nil
  @callback route_options(term(), term()) :: keyword()
  @callback screen_action(term(), keyword()) :: atom()

  @doc false
  def callbacks, do: @callbacks

  @doc false
  def validate!(bridge, env \\ nil) when is_atom(bridge) do
    Code.ensure_compiled!(bridge)

    assert_no_misdeclared_callbacks!(bridge, env)
    assert_behaviour_declared!(bridge, env)
    assert_behaviour_callbacks!(bridge, env)

    bridge
  end

  @doc false
  def session_mfa(bridge, opts \\ [], env \\ nil) when is_atom(bridge) and is_list(opts) do
    validate!(bridge, env)
    {__MODULE__, :generate_session, [bridge, opts]}
  end

  @doc false
  def generate_session(conn, bridge, opts)
      when is_atom(bridge) and is_list(opts) do
    validate!(bridge)
    bridge.generate_session(conn, opts)
  end

  @doc false
  def route_group(bridge, app) when is_atom(bridge) do
    validate!(bridge)
    bridge.route_group(app)
  end

  @doc false
  def route_options(bridge, route, app) when is_atom(bridge) do
    validate!(bridge)
    bridge.route_options(route, app)
  end

  @doc false
  def screen_action(bridge, route, route_options)
      when is_atom(bridge) and is_list(route_options) do
    validate!(bridge)
    bridge.screen_action(route, route_options)
  end

  defp assert_behaviour_declared!(bridge, env) do
    unless behaviour_declared?(bridge) do
      compile_error!(
        env,
        "#{inspect(bridge)} must declare @behaviour AshUi.Phoenix.Bridge and implement callbacks: #{format_callbacks(@callbacks)}"
      )
    end
  end

  defp format_callbacks(callbacks) do
    Enum.map_join(callbacks, ", ", fn {name, arity} -> "#{name}/#{arity}" end)
  end

  defp assert_behaviour_callbacks!(bridge, env) do
    missing =
      Enum.reject(@callbacks, fn {name, arity} ->
        function_exported?(bridge, name, arity)
      end)

    if missing != [] do
      callbacks =
        missing
        |> Enum.map_join(", ", fn {name, arity} -> "#{name}/#{arity}" end)

      compile_error!(
        env,
        "#{inspect(bridge)} must implement AshUi.Phoenix.Bridge callbacks: #{callbacks}"
      )
    end
  end

  defp assert_no_misdeclared_callbacks!(bridge, env) do
    functions = bridge.__info__(:functions)

    Enum.each(@callbacks, fn
      {:generate_session, 2} ->
        arities = callback_arities(functions, :generate_session)

        if arities != [] and 2 not in arities do
          declared =
            arities
            |> Enum.map_join(", ", &"generate_session/#{&1}")

          compile_error!(
            env,
            "#{inspect(bridge)} declares #{declared}, expected generate_session/2"
          )
        end

      {name, arity} ->
        arities = callback_arities(functions, name)

        if arities != [] and arity not in arities do
          declared =
            arities
            |> Enum.map_join(", ", &"#{name}/#{&1}")

          compile_error!(
            env,
            "#{inspect(bridge)} declares #{declared}, expected #{name}/#{arity}"
          )
        end
    end)
  end

  defp callback_arities(functions, name) do
    functions
    |> Enum.filter(fn {function_name, _arity} -> function_name == name end)
    |> Enum.map(fn {_function_name, arity} -> arity end)
    |> Enum.sort()
  end

  defp behaviour_declared?(bridge) do
    bridge
    |> apply(:module_info, [:attributes])
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(__MODULE__)
  end

  defp compile_error!(env, description) do
    raise CompileError,
      file: compile_file(env),
      line: compile_line(env),
      description: description
  end

  defp compile_file(%Macro.Env{file: file}), do: file
  defp compile_file(_env), do: nil

  defp compile_line(%Macro.Env{line: line}), do: line
  defp compile_line(_env), do: nil
end
