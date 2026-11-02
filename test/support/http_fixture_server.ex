defmodule AshUi.TestSupport.HttpFixtureServer do
  @moduledoc false
  def start_link(routes) do
    {:ok, route_agent} = Agent.start_link(fn -> routes end)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    server_pid = spawn_link(fn -> accept_loop(listen_socket, route_agent) end)
    %{agent: route_agent, listen_socket: listen_socket, pid: server_pid, port: port}
  end

  def stop(%{agent: agent, listen_socket: listen_socket, pid: pid}) do
    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :gen_tcp.close(listen_socket)

    if Process.alive?(agent) do
      Agent.stop(agent)
    end
  end

  def put_routes(%{agent: agent}, routes) do
    Agent.update(agent, fn _ -> routes end)
  end

  def url(%{port: port}) do
    "http://127.0.0.1:#{port}"
  end

  defp accept_loop(listen_socket, route_agent) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, route_agent) end)
        accept_loop(listen_socket, route_agent)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, route_agent) do
    with {:ok, raw_request} <- :gen_tcp.recv(socket, 0, 5000) do
      request = parse_request(raw_request)

      route =
        Agent.get(route_agent, fn routes ->
          Map.get(routes, {request.method, request.path}) ||
            Map.get(routes, "#{request.method} #{request.path}") ||
            Map.get(routes, request.path, default_route(request.path))
        end)

      response =
        case route do
          fun when is_function(fun, 1) -> fun.(request)
          other -> other
        end

      :ok = :gen_tcp.send(socket, response(response))
    end

    :gen_tcp.close(socket)
  end

  defp parse_request(raw_request) do
    [head, body] = String.split(raw_request, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, path, _version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.downcase(key), String.trim(value)}
      end)

    %{method: method, path: path, headers: headers, body: body}
  end

  defp response(%{status: status, body: body, content_type: content_type} = route) do
    headers =
      route
      |> Map.get(:headers, [])
      |> Enum.map(fn
        {key, value} -> [key, ": ", value, "\r\n"]
        {key, value, _opts} -> [key, ": ", value, "\r\n"]
      end)

    [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason_phrase(status),
      "\r\n",
      "content-type: ",
      content_type,
      "\r\n",
      "content-length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      headers,
      "connection: close\r\n\r\n",
      body
    ]
  end

  defp reason_phrase(200) do
    "OK"
  end

  defp reason_phrase(204) do
    "No Content"
  end

  defp reason_phrase(302) do
    "Found"
  end

  defp reason_phrase(404) do
    "Not Found"
  end

  defp reason_phrase(_status) do
    "OK"
  end

  defp default_route("/favicon.ico") do
    %{status: 204, body: "", content_type: "text/plain"}
  end

  defp default_route(_path) do
    %{status: 404, body: "<html><body>Not Found</body></html>", content_type: "text/html"}
  end
end
