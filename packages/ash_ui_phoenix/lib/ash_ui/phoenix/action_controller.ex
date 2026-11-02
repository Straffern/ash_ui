defmodule AshUi.Phoenix.ActionController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html, :json]

  import Plug.Conn

  def run(conn, _params) do
    spec = Map.fetch!(conn.private, :ash_ui_action)
    context = request_context(conn, spec)

    case dispatch(spec, conn.params, context) do
      {:ok, {:file, file}} ->
        send_file_response(conn, file)

      {:ok, payload} ->
        json(conn, payload)

      {:error, status, payload} ->
        conn
        |> put_status(status)
        |> json(payload)

      {:error, reason} ->
        conn
        |> put_status(error_status(reason))
        |> json(%{error: error_message(reason)})
    end
  end

  defp dispatch(%{callback: {module, function}} = spec, params, context) do
    apply(module, function, [params, context, spec])
  end

  defp dispatch(%{resource: resource, action: action} = spec, params, context) do
    domain = Map.get(spec, :domain)
    actor = Map.get(context, :actor)
    args = Map.merge(params, Map.get(spec, :args, %{}))

    resource
    |> Ash.ActionInput.for_action(action, args, domain: domain, actor: actor)
    |> Ash.run_action(domain: domain, actor: actor, authorize?: Map.get(spec, :authorize?, true))
    |> map_action_result(spec)
  end

  defp dispatch(_spec, _params, _context), do: {:error, :bad_request, %{error: "Invalid action"}}

  defp map_action_result({:ok, result}, %{response: {module, function}}),
    do: {:ok, apply(module, function, [result])}

  defp map_action_result({:ok, result}, _spec), do: {:ok, result}
  defp map_action_result({:error, reason}, _spec), do: {:error, reason}

  defp request_context(conn, spec) do
    %{
      actor: actor(conn, spec),
      authorization: authorization(conn),
      conn_assigns: conn.assigns,
      headers: conn.req_headers,
      method: conn.method,
      path_info: conn.path_info,
      query_params: conn.query_params,
      request_path: conn.request_path
    }
  end

  defp actor(%{assigns: %{current_user: actor}}, _spec) when not is_nil(actor), do: actor

  defp actor(conn, %{actor_resolver: {module, function}}) do
    apply(module, function, [authorization(conn)])
  end

  defp actor(_conn, %{actor: actor}), do: actor
  defp actor(_conn, _spec), do: nil

  defp authorization(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
  end

  defp send_file_response(conn, %{path: path, content_type: content_type} = file) do
    conn =
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type(content_type || "application/octet-stream")

    try do
      case Map.get(file, :range) do
        {start, length} -> send_file(conn, Map.get(file, :status, 206), path, start, length)
        _none -> send_file(conn, Map.get(file, :status, 200), path)
      end
    after
      cleanup_file_response(file)
    end
  end

  defp cleanup_file_response(%{cleanup: cleanup}) when is_function(cleanup, 0), do: cleanup.()
  defp cleanup_file_response(_file), do: :ok

  defp error_status(%Ash.Error.Forbidden{}), do: :forbidden
  defp error_status(%Ash.Error.Query.NotFound{}), do: :not_found
  defp error_status(_reason), do: :unprocessable_entity

  defp error_message(%{errors: errors}) when is_list(errors) do
    errors
    |> Enum.map(&error_message/1)
    |> Enum.join("; ")
  end

  defp error_message(%_{} = error), do: Exception.message(error)
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)
end
