defmodule AshUi.Phoenix.Router do
  @moduledoc """
  Router macros that discover and mount routed Ash resources.
  """

  alias AshUi.Phoenix.RouteMetadata

  defmacro __using__(opts) do
    presets = Keyword.get(opts, :presets, [AshUi.Phoenix.Presets.AshAuthentication])

    preset_uses =
      Enum.map(presets, fn preset ->
        quote do
          use unquote(preset)
        end
      end)

    quote do
      use Phoenix.Router, helpers: false
      unquote_splicing(preset_uses)

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
      import AshUi.Phoenix.Router
    end
  end

  defmacro ash_ui_browser_pipeline(opts \\ []) do
    name = Keyword.get(opts, :name, :browser)
    load_from_session_otp_app = Keyword.get(opts, :load_from_session_otp_app)

    load_from_session =
      if load_from_session_otp_app do
        quote do
          plug(:load_from_session, otp_app: unquote(load_from_session_otp_app))
        end
      end

    quote do
      pipeline unquote(name) do
        plug(:accepts, ["html"])
        plug(:fetch_session)
        plug(:put_root_layout, html: {AshUi.Phoenix.RootLayout, :render})
        plug(:protect_from_forgery)
        plug(:put_secure_browser_headers)
        unquote(load_from_session)
      end
    end
  end

  defmacro ash_ui_api_pipeline(opts \\ []) do
    name = Keyword.get(opts, :name, :api)
    load_from_session_otp_app = Keyword.get(opts, :load_from_session_otp_app)
    bearer_csrf_skip? = Keyword.get(opts, :bearer_csrf_skip?, false)
    protect_from_forgery? = Keyword.get(opts, :protect_from_forgery?, false)

    fetch_session? =
      Keyword.get(
        opts,
        :fetch_session?,
        protect_from_forgery? or not is_nil(load_from_session_otp_app)
      )

    fetch_session =
      if fetch_session? do
        quote do
          plug(:fetch_session)
        end
      end

    load_from_session =
      if load_from_session_otp_app do
        quote do
          plug(:load_from_session, otp_app: unquote(load_from_session_otp_app))
        end
      end

    bearer_csrf_skip =
      if bearer_csrf_skip? do
        quote do
          plug(AshUi.Phoenix.BearerCsrfSkip)
        end
      end

    csrf =
      if protect_from_forgery? do
        quote do
          plug(:protect_from_forgery)
        end
      end

    quote do
      pipeline unquote(name) do
        plug(:accepts, ["json"])
        unquote(fetch_session)
        unquote(load_from_session)
        plug(:put_secure_browser_headers)
        unquote(bearer_csrf_skip)
        unquote(csrf)
      end
    end
  end

  defmacro ash_ui_live_domains(name, domains, opts) do
    pipeline = Keyword.get(opts, :pipeline)
    on_mount = Keyword.fetch!(opts, :on_mount)
    session = Keyword.fetch!(opts, :session)

    pipe_through =
      if pipeline do
        quote do
          pipe_through(unquote(pipeline))
        end
      end

    quote do
      live_session unquote(name),
        on_mount: unquote(on_mount),
        session: unquote(session) do
        scope "/" do
          unquote(pipe_through)
          ash_ui_routes(domains: unquote(domains))
        end
      end
    end
  end

  defmacro ash_ui_bridge_live_domains(name, domains, opts) do
    bridge = opts |> Keyword.fetch!(:bridge) |> Macro.expand(__CALLER__)
    mount = Keyword.get(opts, :mount, :default)
    pipeline = Keyword.get(opts, :pipeline)

    session =
      Keyword.get(opts, :session, AshUi.Phoenix.Bridge.session_mfa(bridge, [], __CALLER__))

    quote do
      ash_ui_live_domains(
        unquote(name),
        unquote(domains),
        on_mount: [{unquote(bridge), unquote(mount)}],
        pipeline: unquote(pipeline),
        session: unquote(Macro.escape(session))
      )
    end
  end

  defmacro ash_ui_action_scope(path, pipeline, actions) do
    action_calls =
      Enum.map(actions, fn spec ->
        {method, route_path, opts} = action_scope_spec(spec)

        quote do
          ash_ui_action(unquote(method), unquote(route_path), unquote(opts))
        end
      end)

    pipe_through =
      if pipeline do
        quote do
          pipe_through(unquote(pipeline))
        end
      end

    quote do
      scope unquote(path) do
        unquote(pipe_through)
        unquote_splicing(action_calls)
      end
    end
  end

  defmacro ash_ui_authentication_routes(opts) do
    pipeline = Keyword.get(opts, :pipeline, :browser)
    scope_path = Keyword.get(opts, :scope, "/")
    user_resource = Keyword.fetch!(opts, :user_resource)
    otp_app = Keyword.get(opts, :otp_app)
    resources = Keyword.get(opts, :resources, [user_resource])
    auth_path = Keyword.get(opts, :auth_path, "/auth")
    register_path = Keyword.get(opts, :register_path, "/register")
    reset_path = Keyword.get(opts, :reset_path, "/reset")
    auth_routes_prefix = Keyword.get(opts, :auth_routes_prefix, "/auth")

    overrides =
      Keyword.get(
        opts,
        :overrides,
        AshUi.Phoenix.Presets.DaisyUI.ash_authentication_overrides()
      )

    quote do
      scope unquote(scope_path) do
        pipe_through(unquote(pipeline))

        auth_routes(AshUi.Phoenix.AuthController, unquote(user_resource),
          path: unquote(auth_path)
        )

        sign_out_route(AshUi.Phoenix.AuthController, "/sign-out",
          otp_app: unquote(otp_app)
        )

        sign_in_route(
          register_path: unquote(register_path),
          reset_path: unquote(reset_path),
          auth_routes_prefix: unquote(auth_routes_prefix),
          otp_app: unquote(otp_app),
          resources: unquote(resources),
          on_mount: [{AshUi.Phoenix.LiveSession, :live_no_user}],
          overrides: unquote(Macro.escape(overrides))
        )

        reset_route(
          auth_routes_prefix: unquote(auth_routes_prefix),
          otp_app: unquote(otp_app),
          resources: unquote(resources),
          overrides: unquote(Macro.escape(overrides))
        )

        confirm_route(unquote(user_resource), :confirm_new_user,
          auth_routes_prefix: unquote(auth_routes_prefix),
          overrides: unquote(Macro.escape(overrides))
        )
      end
    end
  end

  defmacro ash_ui_action(method, path, opts) do
    method = Macro.expand(method, __CALLER__)

    quote do
      Phoenix.Router.match(
        unquote(method),
        unquote(path),
        AshUi.Phoenix.ActionController,
        :run,
        private: %{ash_ui_action: Map.new(unquote(opts))}
      )
    end
  end

  defmacro ash_ui_file_serve(path, opts) do
    quote do
      forward(unquote(path), AshUi.Phoenix.FileServe, unquote(opts))
    end
  end

  defmacro ash_ui_routes(opts) do
    __routes_ast__(opts, __CALLER__)
  end

  @doc false
  def __routes_ast__(opts, caller) when is_list(opts) do
    domains =
      opts
      |> Keyword.fetch!(:domains)
      |> List.wrap()
      |> Enum.map(&Macro.expand(&1, caller))

    resources =
      domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.uniq()

    Enum.each(resources, &Code.ensure_compiled!/1)
    routed_resources = Enum.filter(resources, &(declared_routes(&1) != []))

    artifact_resources =
      Enum.filter(routed_resources, &AshUi.Patch.Compiler.compilable?/1)

    navigation_routes =
      for resource <- resources,
          {path, _query} <- declared_routes(resource),
          is_binary(path),
          do: path

    Enum.each(artifact_resources, fn resource ->
      table =
        AshUi.Patch.Compiler.compile(resource,
          target: AshUi.Phoenix.RenderTarget,
          navigation_routes: navigation_routes
        )

      AshUi.Phoenix.PatchArtifact.install(
        resource,
        %{view: table},
        Mix.Project.compile_path()
      )
    end)

    routes =
      routed_resources
      |> Enum.flat_map(fn resource ->
        for {path, query} <- declared_routes(resource) do
          %{path: path, query: query, resource: resource}
        end
      end)
      |> Enum.filter(&is_binary(&1.path))
      |> Enum.sort_by(&route_specificity/1, :desc)
      |> Enum.map(fn route ->
        route_metadata = RouteMetadata.new(route.resource, route.path, route.query)
        live_call(route, put_route_metadata([], route_metadata))
      end)

    {:__block__, [], routes}
  end

  defp action_scope_spec({:{}, _meta, [method, path, opts]}), do: {method, path, opts}
  defp action_scope_spec({method, path, opts}), do: {method, path, opts}

  # EVERY route a resource declares mounts — routing is 100% DSL derived.
  defp declared_routes(resource) do
    cond do
      function_exported?(resource, :__ash_ui_routes__, 0) ->
        resource.__ash_ui_routes__()

      function_exported?(resource, :__ash_ui_route__, 0) ->
        [resource.__ash_ui_route__()]

      true ->
        []
    end
  end

  defmacro ash_ui_auth_routes(opts \\ []) do
    path = Keyword.get(opts, :path, "/auth")
    otp_app = Keyword.fetch!(opts, :otp_app)
    sign_out_path = Keyword.get(opts, :sign_out_path, "/sign-out")
    controller = Keyword.get(opts, :controller, quote(do: AuthController))

    resources = AshAuthentication.authenticated_resources(otp_app)

    quote do
      auth_routes(unquote(controller), unquote(resources), path: unquote(path))
      sign_out_route(unquote(controller), unquote(sign_out_path))
    end
  end

  @doc false
  def __live__(router, live_view, action, opts)
      when is_atom(router) and is_atom(live_view) and is_list(opts) do
    live_session =
      Module.get_attribute(router, :phoenix_live_session_current) ||
        %{name: :default, extra: %{}}

    helpers = Module.get_attribute(router, :phoenix_helpers)
    {private, metadata, warn_on_verify, opts} = validate_live_opts!(opts)

    opts =
      opts
      |> Keyword.put(:router, router)
      |> Keyword.put(:action, action)

    {as_helper, as_action} =
      if helpers do
        inferred_as(live_view, opts[:as], action)
      else
        {nil, action || live_view}
      end

    metadata =
      metadata
      |> Map.put(:phoenix_live_view, {live_view, action, opts, live_session})
      |> Map.put(:mfa, {live_view, :__live__, 0})
      |> Map.put(:log_module, live_view)

    {as_action,
     alias: false,
     as: as_helper,
     warn_on_verify: warn_on_verify,
     private: Map.put(private, :phoenix_live_view, {live_view, opts, live_session}),
     metadata: metadata}
  end

  defp live_call(route, route_options) do
    quote do
      {action, router_options} =
        AshUi.Phoenix.Router.__live__(
          __MODULE__,
          AshUi.Phoenix.BridgeLive,
          unquote(route.resource),
          unquote(Macro.escape(route_options))
        )

      Phoenix.Router.get(unquote(route.path), Phoenix.LiveView.Plug, action, router_options)
    end
  end

  defp validate_live_opts!(opts) when is_list(opts) do
    {private, opts} = Keyword.pop(opts, :private, %{})
    {metadata, opts} = Keyword.pop(opts, :metadata, %{})
    {warn_on_verify, opts} = Keyword.pop(opts, :warn_on_verify, false)

    Enum.each(opts, fn
      {:container, {tag, attrs}} when is_atom(tag) and is_list(attrs) ->
        :ok

      {:container, val} ->
        raise ArgumentError,
              "expected live :container to be a tuple matching {atom, attrs :: list}, got: #{inspect(val)}"

      {:as, as} when is_atom(as) ->
        :ok

      {:as, bad_val} ->
        raise ArgumentError, "expected live :as to be an atom, got: #{inspect(bad_val)}"

      {key, %{} = _meta} when key in [:metadata, :private] ->
        :ok

      {key, bad_val} when key in [:metadata, :private] ->
        raise ArgumentError, "expected live :#{key} to be a map, got: #{inspect(bad_val)}"

      {key, _val} ->
        raise ArgumentError,
              "unknown live option :#{key}. Supported options include: :container, :as, :metadata, :private, :warn_on_verify."
    end)

    {Map.new(private), Map.new(metadata), warn_on_verify, opts}
  end

  defp inferred_as(live_view, as, nil), do: {as || :live, live_view}

  defp inferred_as(live_view, nil, action) do
    live_view
    |> Module.split()
    |> Enum.drop_while(&(not String.ends_with?(&1, "Live")))
    |> Enum.map(&(&1 |> String.replace_suffix("Live", "") |> Macro.underscore()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("_")
    |> case do
      "" ->
        {nil, action}

      inferred ->
        {String.to_atom(inferred), action}
    end
  end

  defp inferred_as(_live_view, as, action), do: {as, action}

  defp put_route_metadata(route_options, %RouteMetadata{} = route_metadata) do
    route_options
    |> Keyword.update(:metadata, %{ash_ui_route_metadata: route_metadata}, fn metadata ->
      metadata
      |> Map.new()
      |> Map.put(:ash_ui_route_metadata, route_metadata)
    end)
    |> Keyword.update(:private, %{ash_ui_route_metadata: route_metadata}, fn private ->
      private
      |> Map.new()
      |> Map.put(:ash_ui_route_metadata, route_metadata)
    end)
  end

  defp route_specificity(%{path: path}) when is_binary(path) do
    segments = String.split(path, "/", trim: true)

    static_segments = Enum.count(segments, &(not String.starts_with?(&1, ":")))
    param_segments = Enum.count(segments, &String.starts_with?(&1, ":"))

    {static_segments, -param_segments, length(segments)}
  end
end
