defmodule AshUi.Datastar.SDKTestPlug do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn
  alias AshUi.Datastar.SSE

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{request_path: "/test"} = conn, _opts) do
    with {:ok, input, conn} <- input(conn),
         %{"events" => events} when is_list(events) <- input do
      body = events |> Enum.map(&event/1) |> SSE.encode()

      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("content-type", "text/event-stream")
      |> send_resp(200, body)
    else
      _ -> send_resp(conn, 400, "invalid SDK test request")
    end
  end

  def call(conn, _opts), do: send_resp(conn, 404, "not found")

  defp input(%Plug.Conn{method: method} = conn) when method in ["GET", "DELETE"] do
    conn = fetch_query_params(conn)

    case Jason.decode(Map.get(conn.query_params, "datastar", "")) do
      {:ok, input} -> {:ok, input, conn}
      error -> error
    end
  end

  defp input(conn) do
    with {:ok, body, conn} <- read_all(conn, ""),
         {:ok, input} <- Jason.decode(body) do
      {:ok, input, conn}
    end
  end

  defp read_all(conn, acc) do
    case read_body(conn) do
      {:ok, body, conn} -> {:ok, acc <> body, conn}
      {:more, body, conn} -> read_all(conn, acc <> body)
      error -> error
    end
  end

  defp event(%{"type" => "patchElements"} = input) do
    SSE.patch_elements(Map.get(input, "elements", ""), element_opts(input))
  end

  defp event(%{"type" => "patchSignals"} = input) do
    signals = Map.get(input, "signals-raw", Map.get(input, "signals", %{}))

    SSE.patch_signals(signals,
      event_id: input["eventId"],
      retry_duration: Map.get(input, "retryDuration", 1_000),
      only_if_missing: Map.get(input, "onlyIfMissing", false)
    )
  end

  defp event(%{"type" => "executeScript"} = input) do
    SSE.execute_script(Map.get(input, "script", ""),
      event_id: input["eventId"],
      retry_duration: Map.get(input, "retryDuration", 1_000),
      auto_remove: Map.get(input, "autoRemove", true),
      attributes: Map.get(input, "attributes", %{})
    )
  end

  defp element_opts(input) do
    [
      event_id: input["eventId"],
      retry_duration: Map.get(input, "retryDuration", 1_000),
      selector: input["selector"],
      mode: Map.get(input, "mode", "outer"),
      namespace: Map.get(input, "namespace", "html"),
      use_view_transition: Map.get(input, "useViewTransition", false),
      view_transition_selector: input["viewTransitionSelector"]
    ]
  end
end
