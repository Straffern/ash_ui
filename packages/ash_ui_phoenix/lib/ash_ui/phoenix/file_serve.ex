defmodule AshUi.Phoenix.FileServe do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts) do
    opts
    |> Map.new()
    |> Map.update!(:root, &Path.expand/1)
    |> Map.put_new(:content_type, "application/octet-stream")
  end

  @impl true
  def call(conn, %{root: root} = opts) do
    key = Enum.join(conn.path_info, "/")
    path = key |> Path.join("") |> Path.expand(root)

    if key != "" and String.starts_with?(path, root <> "/") and File.regular?(path) do
      serve(conn, path, opts)
    else
      conn
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end

  defp serve(conn, path, opts) do
    size = File.stat!(path).size

    conn =
      conn
      |> put_resp_header("content-type", Map.fetch!(opts, :content_type))
      |> put_resp_header("accept-ranges", "bytes")

    case get_req_header(conn, "range") do
      ["bytes=" <> range] -> serve_range(conn, path, size, range)
      _other -> conn |> send_file(200, path) |> halt()
    end
  end

  defp serve_range(conn, path, size, range) do
    case parse_range(range, size) do
      {:ok, start, finish} ->
        length = finish - start + 1

        conn
        |> put_resp_header("content-range", "bytes #{start}-#{finish}/#{size}")
        |> put_resp_header("content-length", Integer.to_string(length))
        |> send_file(206, path, start, length)
        |> halt()

      :error ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "Range Not Satisfiable")
        |> halt()
    end
  end

  defp parse_range(_range, size) when size <= 0, do: :error

  defp parse_range(range, size) do
    with false <- String.contains?(range, ","),
         [start_text, end_text] <- String.split(range, "-", parts: 2),
         {:ok, start, finish} <- parse_range_bounds(start_text, end_text, size),
         true <- start <= finish and start >= 0 and finish < size do
      {:ok, start, finish}
    else
      _other -> :error
    end
  end

  defp parse_range_bounds("", suffix_text, size) do
    with {suffix_length, ""} <- Integer.parse(suffix_text),
         true <- suffix_length > 0 do
      {:ok, max(size - suffix_length, 0), size - 1}
    else
      _other -> :error
    end
  end

  defp parse_range_bounds(start_text, "", size) do
    with {start, ""} <- Integer.parse(start_text),
         true <- start < size do
      {:ok, start, size - 1}
    else
      _other -> :error
    end
  end

  defp parse_range_bounds(start_text, end_text, size) do
    with {start, ""} <- Integer.parse(start_text),
         {finish, ""} <- Integer.parse(end_text),
         true <- start < size do
      {:ok, start, min(finish, size - 1)}
    else
      _other -> :error
    end
  end
end
