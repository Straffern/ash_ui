defmodule AshUi.Phoenix.Endpoint do
  @moduledoc false

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    {router, generated_router} = router(opts, __CALLER__)
    session_options = Keyword.fetch!(opts, :session_options)
    static_paths = Keyword.get(opts, :static_paths, [])

    extra_static =
      opts
      |> Keyword.get(:extra_static, [])
      |> expand_static_specs(__CALLER__)

    desktop? = Keyword.get(opts, :desktop?, false)
    gzip = Keyword.get(opts, :gzip, false)
    parser_opts = Keyword.get(opts, :parser_opts, [])
    font_opts = Keyword.get(opts, :font_opts)

    dynamic_static =
      opts
      |> Keyword.get(:dynamic_static)
      |> expand_runtime_opt(__CALLER__)

    desktop_auth? = Keyword.get(opts, :desktop_auth?)
    endpoint = if desktop?, do: quote(do: Desktop.Endpoint), else: quote(do: Phoenix.Endpoint)

    ets_session_table =
      if Keyword.get(session_options, :store) == :ets do
        Keyword.get(session_options, :table)
      end

    # An empty static_paths list must mean "no root static serving" — Plug.Static
    # treats `only: []` as UNFILTERED, which both serves the whole priv/static
    # tree at "/" and path-validates every request (raising InvalidPathError on
    # ":"-bearing route segments such as inbox:agent:codex before the router).
    root_static_specs =
      case static_paths do
        [] -> []
        paths -> [{otp_app, "/", [only: paths]}]
      end

    static_specs = root_static_specs ++ normalize_extra_static(extra_static)

    static_plugs =
      Enum.map(
        static_specs,
        fn {from, at, static_opts} ->
          static_opts = Macro.escape(static_opts)

          quote do
            plug(
              Plug.Static,
              Keyword.merge(
                [
                  at: unquote(at),
                  from: unquote(Macro.escape(from)),
                  gzip: unquote(gzip),
                  raise_on_missing_only: false
                ],
                unquote(static_opts)
              )
            )
          end
        end
      )

    font_plug =
      if font_opts do
        quote do
          plug(AshUi.Phoenix.FontServe, unquote(font_opts))
        end
      end

    dynamic_static_plug =
      if dynamic_static do
        quote do
          plug(AshUi.Phoenix.DynamicStatic, unquote(Macro.escape(dynamic_static)))
        end
      end

    desktop_auth_plug =
      if desktop_auth? do
        quote do
          plug(:maybe_desktop_auth)

          defp maybe_desktop_auth(conn, _opts) do
            {module, function_name, args} = unquote(desktop_auth?)

            if not __MODULE__.config(:code_reloader) and apply(module, function_name, args) do
              Desktop.Auth.call(conn, Desktop.Auth.init([]))
            else
              conn
            end
          end
        end
      end

    quote do
      unquote(generated_router)

      use unquote(endpoint), otp_app: unquote(otp_app)

      @session_options unquote(Macro.escape(session_options))
      @ash_ui_ets_session_table unquote(ets_session_table)

      socket("/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [session: @session_options]],
        longpoll: [connect_info: [session: @session_options]]
      )

      unquote(font_plug)
      unquote_splicing(static_plugs)
      plug(AshUi.Phoenix.Assets, gzip: unquote(gzip))
      unquote(dynamic_static_plug)

      plug(Plug.RequestId)
      plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

      plug(
        Plug.Parsers,
        Keyword.merge(
          [
            parsers: [:urlencoded, :multipart, :json],
            pass: ["*/*"],
            json_decoder: Phoenix.json_library()
          ],
          unquote(parser_opts)
        )
      )

      plug(Plug.MethodOverride)
      plug(Plug.Head)
      plug(:ensure_ash_ui_ets_session_table)
      plug(Plug.Session, @session_options)
      unquote(desktop_auth_plug)
      plug(:put_ash_ui_app_header)
      plug(unquote(router))

      defp ensure_ash_ui_ets_session_table(conn, _opts) do
        case @ash_ui_ets_session_table do
          table when is_atom(table) ->
            case :ets.info(table) do
              :undefined ->
                try do
                  :ets.new(table, [
                    :named_table,
                    :public,
                    read_concurrency: true
                  ])
                rescue
                  ArgumentError ->
                    :ok
                end

              _info ->
                :ok
            end

          _other ->
            :ok
        end

        conn
      end

      defp put_ash_ui_app_header(conn, _opts) do
        Plug.Conn.put_resp_header(conn, "x-app-domain", Atom.to_string(unquote(otp_app)))
      end
    end
  end

  defp router(opts, caller) do
    case {Keyword.get(opts, :router), Keyword.get(opts, :blueprint_router)} do
      {router, nil} when not is_nil(router) ->
        {router, nil}

      {nil, blueprint_router_opts} when is_list(blueprint_router_opts) ->
        router = Module.concat(caller.module, RouteBridge)
        {router, generated_router(router, blueprint_router_opts)}

      {nil, nil} ->
        raise ArgumentError, "expected :router or :blueprint_router option"

      {_router, _blueprint_router_opts} ->
        raise ArgumentError, "expected only one of :router or :blueprint_router"
    end
  end

  defp generated_router(router, opts) do
    browser_pipeline = Keyword.get(opts, :browser_pipeline, [])
    authentication_routes = Keyword.get(opts, :authentication_routes)
    live_session_name = Keyword.get(opts, :live_session, :signed_in_blueprint)
    live_apps = Keyword.fetch!(opts, :live_apps)
    action_scopes = Keyword.get(opts, :action_scopes, [])
    on_mount = Keyword.fetch!(opts, :on_mount)
    pipeline = Keyword.get(opts, :pipeline, :browser)
    session = Keyword.fetch!(opts, :session)

    browser_pipeline_ast =
      if browser_pipeline == false do
        nil
      else
        quote do
          ash_ui_browser_pipeline(unquote(browser_pipeline))
        end
      end

    router_presets =
      if authentication_routes, do: [AshUi.Phoenix.Presets.AshAuthentication], else: []

    authentication_routes_ast =
      if authentication_routes do
        quote do
          ash_ui_authentication_routes(unquote(authentication_routes))
        end
      end

    quote do
      defmodule unquote(router) do
        @moduledoc false

        use AshUi.Phoenix.Router, presets: unquote(router_presets)

        unquote(browser_pipeline_ast)
        unquote(authentication_routes_ast)
        unquote_splicing(generated_action_scopes(action_scopes))

        ash_ui_live_apps(
          unquote(live_session_name),
          unquote(live_apps),
          on_mount: unquote(on_mount),
          pipeline: unquote(pipeline),
          session: unquote(session)
        )
      end
    end
  end

  defp generated_action_scopes(action_scopes) do
    Enum.map(action_scopes, fn
      {:{}, _meta, [path, pipeline, actions]} ->
        generated_action_scope(path, pipeline, actions)

      {path, pipeline, actions} ->
        generated_action_scope(path, pipeline, Macro.escape(actions))
    end)
  end

  defp generated_action_scope(path, pipeline, actions) do
    quote do
      ash_ui_action_scope(
        unquote(path),
        unquote(pipeline),
        unquote(actions)
      )
    end
  end

  defp normalize_extra_static(static_specs) do
    Enum.map(static_specs, fn
      {:{}, _meta, [from, at, opts]} when is_binary(at) -> {from, at, static_opts(opts)}
      {:{}, _meta, [from, at, opts]} -> {from, at, static_opts(opts)}
      {:{}, _meta, [from, opts]} -> {from, "/", static_opts(opts)}
      {from, at, opts} when is_binary(at) -> {from, at, static_opts(opts)}
      {from, opts} -> {from, "/", static_opts(opts)}
    end)
  end

  defp static_opts(:all), do: []
  defp static_opts(nil), do: []
  defp static_opts(opts) when is_list(opts), do: [only: opts]
  defp static_opts(opts), do: [only: opts]

  defp expand_static_specs(static_specs, caller) do
    expand_macro_literal(static_specs, caller)
  end

  defp expand_runtime_opt(nil, _caller), do: nil

  defp expand_runtime_opt(opt, caller) do
    expand_macro_literal(opt, caller)
  end

  defp expand_macro_literal(value, caller) do
    value
    |> Macro.prewalk(fn
      {:__aliases__, _meta, _parts} = ast -> Macro.expand(ast, caller)
      {:@, _meta, [{_name, _name_meta, _context}]} = ast -> Macro.expand(ast, caller)
      ast -> ast
    end)
    |> literal_value()
  rescue
    _error in [ArgumentError, FunctionClauseError] -> Macro.expand(value, caller)
  end

  defp literal_value(value)
       when is_atom(value) or is_binary(value) or is_number(value) or is_boolean(value) or
              is_nil(value),
       do: value

  defp literal_value(list) when is_list(list), do: Enum.map(list, &literal_value/1)

  defp literal_value({:{}, _meta, values}),
    do: values |> Enum.map(&literal_value/1) |> List.to_tuple()

  defp literal_value({:%{}, _meta, pairs}),
    do: Map.new(pairs, fn {key, value} -> {literal_value(key), literal_value(value)} end)

  defp literal_value(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&literal_value/1) |> List.to_tuple()
end
