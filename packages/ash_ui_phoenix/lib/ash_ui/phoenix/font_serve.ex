defmodule AshUi.Phoenix.FontServe do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(%{request_path: "/fonts/" <> requested} = conn, opts) do
    files = Map.get(opts, :files, %{})

    case Map.fetch(files, requested) do
      {:ok, filename} ->
        root = root!(opts)

        conn
        |> put_resp_content_type(Map.get(opts, :content_type, "font/ttf"))
        |> send_file(200, Path.join(root, filename))
        |> halt()

      :error ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp root!(%{root: {module, function_name, args}}), do: apply(module, function_name, args)
  defp root!(%{root: root}) when is_binary(root), do: root
end
