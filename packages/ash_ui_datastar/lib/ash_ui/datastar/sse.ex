defmodule AshUi.Datastar.SSE do
  @moduledoc """
  Datastar v1 server-sent event encoder and streaming compression wrapper.

  The bytes and defaults follow `sdk/datastar-sdk-config-v1.json` and the
  reference generator. gzip is implemented with Erlang `:zlib` and every
  event is emitted with a synchronous deflate flush.
  """

  import Plug.Conn

  @patch_elements "datastar-patch-elements"
  @patch_signals "datastar-patch-signals"
  @default_retry 1_000
  @modes ~w(outer inner remove replace prepend append before after)a
  @namespaces ~w(html svg mathml)a

  defmodule Event do
    @moduledoc false
    defstruct [:type, :event_id, retry: 1_000, data: [], meta: %{}]
  end

  defmodule Encoder do
    @moduledoc false
    defstruct [:encoding, :zlib]
  end

  @type event :: %Event{}

  @spec send(String.t() | atom(), [String.t()], keyword()) :: event()
  def send(type, data_lines, opts \\ []) when is_list(data_lines) do
    %Event{
      type: to_string(type),
      event_id: Keyword.get(opts, :event_id),
      retry: Keyword.get(opts, :retry_duration, @default_retry),
      data: Enum.map(data_lines, &to_string/1),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @spec patch_elements(iodata(), keyword()) :: event()
  def patch_elements(elements \\ "", opts \\ []) do
    mode = opts |> Keyword.get(:mode, :outer) |> normalize_enum!(@modes, :mode)
    namespace = opts |> Keyword.get(:namespace, :html) |> normalize_enum!(@namespaces, :namespace)
    selector = Keyword.get(opts, :selector)
    transitions? = Keyword.get(opts, :use_view_transition, false)

    lines =
      []
      |> maybe_line(selector, "selector ")
      |> maybe_nondefault(mode, :outer, "mode ")
      |> maybe_nondefault(namespace, :html, "namespace ")
      |> maybe_truthy(transitions?, "useViewTransition true")
      |> maybe_transition_selector(transitions?, Keyword.get(opts, :view_transition_selector))
      |> Kernel.++(prefixed_lines("elements ", IO.iodata_to_binary(elements)))

    send(@patch_elements, lines,
      event_id: Keyword.get(opts, :event_id),
      retry_duration: Keyword.get(opts, :retry_duration, @default_retry),
      meta: Keyword.get(opts, :meta, %{})
    )
  end

  @spec patch_signals(map() | iodata(), keyword()) :: event()
  def patch_signals(signals, opts \\ []) do
    json = if is_map(signals), do: Jason.encode!(signals), else: IO.iodata_to_binary(signals)

    lines =
      []
      |> maybe_truthy(Keyword.get(opts, :only_if_missing, false), "onlyIfMissing true")
      |> Kernel.++(prefixed_lines("signals ", json, include_empty?: true))

    send(@patch_signals, lines,
      event_id: Keyword.get(opts, :event_id),
      retry_duration: Keyword.get(opts, :retry_duration, @default_retry)
    )
  end

  @spec execute_script(iodata(), keyword()) :: event()
  def execute_script(script, opts \\ []) do
    attributes =
      opts
      |> Keyword.get(:attributes, [])
      |> normalize_script_attributes()
      |> maybe_auto_remove(Keyword.get(opts, :auto_remove, true))

    tag = ["<script", attributes, ">", script, "</script>"]

    patch_elements(tag,
      selector: "body",
      mode: :append,
      event_id: Keyword.get(opts, :event_id),
      retry_duration: Keyword.get(opts, :retry_duration, @default_retry),
      meta: Keyword.get(opts, :meta, %{})
    )
  end

  @spec encode(event() | [event()]) :: binary()
  def encode(events) when is_list(events),
    do: events |> Enum.map(&encode_event/1) |> IO.iodata_to_binary()

  def encode(%Event{} = event), do: encode_event(event) |> IO.iodata_to_binary()

  @spec encode_event(event()) :: iodata()
  def encode_event(%Event{} = event) do
    [
      "event: ",
      event.type,
      "\n",
      if(present?(event.event_id), do: ["id: ", event.event_id, "\n"], else: []),
      if(is_integer(event.retry) and event.retry > 0 and event.retry != @default_retry,
        do: ["retry: ", Integer.to_string(event.retry), "\n"],
        else: []
      ),
      Enum.map(event.data, &["data: ", &1, "\n"]),
      "\n"
    ]
  end

  @doc "Datastar SSE response headers. Connection is emitted only for HTTP/1.x."
  def headers(protocol \\ :http1) do
    base = [{"cache-control", "no-cache"}, {"content-type", "text/event-stream"}]

    if protocol in [:http1, :http10, :http11],
      do: base ++ [{"connection", "keep-alive"}],
      else: base
  end

  @doc "Negotiate the supported stream encodings (gzip and identity)."
  def negotiate(accept_encoding) do
    accepted = parse_accept_encoding(accept_encoding || "")
    gzip_q = quality(accepted, "gzip")
    identity_q = quality(accepted, "identity", 1.0)

    cond do
      gzip_q > 0 -> {:ok, :gzip}
      identity_q > 0 -> {:ok, :identity}
      true -> {:error, :not_acceptable}
    end
  end

  @doc "Encode events as per-event flushed chunks plus the compression trailer."
  def compressed_chunks(events, encoding) when is_list(events) do
    case encoding do
      :identity -> {Enum.map(events, &encode/1), <<>>}
      :gzip -> gzip_chunks(events)
    end
  end

  @doc "Send and flush each event on a Plug chunked response."
  def send_events(conn, events, opts \\ []) do
    case open_stream(conn, opts) do
      {:ok, conn, encoder} ->
        {conn, encoder} =
          Enum.reduce_while(events, {conn, encoder}, fn event, {conn, encoder} ->
            case write_event(conn, encoder, event) do
              {:ok, conn, encoder} -> {:cont, {conn, encoder}}
              {:error, conn, encoder} -> {:halt, {conn, encoder}}
            end
          end)

        close_stream(conn, encoder)

      {:error, conn} ->
        conn
    end
  end

  @doc "Open an SSE response and initialize its negotiated streaming encoder."
  def open_stream(conn, opts \\ []) do
    protocol = Keyword.get(opts, :protocol, :http1)

    with {:ok, encoding} <- negotiate(get_req_header(conn, "accept-encoding") |> List.first()) do
      conn =
        Enum.reduce(headers(protocol), conn, fn {key, value}, acc ->
          put_resp_header(acc, key, value)
        end)

      conn =
        if encoding == :gzip, do: put_resp_header(conn, "content-encoding", "gzip"), else: conn

      conn = send_chunked(conn, 200)
      {:ok, conn, encoder(encoding)}
    else
      {:error, :not_acceptable} ->
        {:error, send_resp(conn, 406, "no acceptable SSE content encoding")}
    end
  end

  @doc "Write one event and synchronously flush its compression frame."
  def write_event(conn, %Encoder{} = encoder, %Event{} = event),
    do: write_raw(conn, encoder, encode(event))

  @doc "Write raw SSE bytes (used for comment heartbeats) with a stream flush."
  def write_raw(conn, %Encoder{encoding: :identity} = encoder, bytes) do
    case chunk(conn, bytes) do
      {:ok, conn} -> {:ok, conn, encoder}
      {:error, _reason} -> {:error, conn, encoder}
    end
  end

  def write_raw(conn, %Encoder{encoding: :gzip, zlib: z} = encoder, bytes) do
    compressed = z |> :zlib.deflate(bytes, :sync) |> IO.iodata_to_binary()

    case chunk(conn, compressed) do
      {:ok, conn} -> {:ok, conn, encoder}
      {:error, _reason} -> {:error, conn, encoder}
    end
  end

  @doc "Finish a finite stream and release compression state."
  def close_stream(conn, %Encoder{encoding: :identity}), do: conn

  def close_stream(conn, %Encoder{encoding: :gzip, zlib: z}) do
    trailer = z |> :zlib.deflate(<<>>, :finish) |> IO.iodata_to_binary()

    try do
      case chunk(conn, trailer) do
        {:ok, conn} -> conn
        {:error, _reason} -> conn
      end
    after
      :zlib.close(z)
    end
  end

  defp gzip_chunks(events) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)

    try do
      chunks =
        Enum.map(events, fn event ->
          z |> :zlib.deflate(encode(event), :sync) |> IO.iodata_to_binary()
        end)

      trailer = z |> :zlib.deflate(<<>>, :finish) |> IO.iodata_to_binary()
      {chunks, trailer}
    after
      :zlib.close(z)
    end
  end

  defp encoder(:identity), do: %Encoder{encoding: :identity}

  defp encoder(:gzip) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)
    %Encoder{encoding: :gzip, zlib: z}
  end

  defp prefixed_lines(prefix, value, opts \\ [])

  defp prefixed_lines(prefix, "", opts) do
    if Keyword.get(opts, :include_empty?, false), do: [prefix], else: []
  end

  defp prefixed_lines(prefix, value, _opts),
    do: value |> String.split("\n") |> Enum.map(&(prefix <> &1))

  defp maybe_line(lines, value, _prefix) when value in [nil, ""], do: lines
  defp maybe_line(lines, value, prefix), do: lines ++ [prefix <> to_string(value)]
  defp maybe_nondefault(lines, value, value, _prefix), do: lines
  defp maybe_nondefault(lines, value, _default, prefix), do: lines ++ [prefix <> to_string(value)]
  defp maybe_truthy(lines, true, line), do: lines ++ [line]
  defp maybe_truthy(lines, _false, _line), do: lines

  defp maybe_transition_selector(lines, true, value) when value not in [nil, ""],
    do: lines ++ ["viewTransitionSelector " <> value]

  defp maybe_transition_selector(lines, _enabled, _value), do: lines

  defp normalize_enum!(value, allowed, name) do
    value = if is_binary(value), do: String.to_existing_atom(value), else: value

    if value in allowed,
      do: value,
      else: raise(ArgumentError, "invalid #{name}: #{inspect(value)}")
  rescue
    ArgumentError -> raise ArgumentError, "invalid #{name}: #{inspect(value)}"
  end

  defp normalize_script_attributes(attrs) when is_map(attrs),
    do:
      attrs
      |> Enum.sort_by(&to_string(elem(&1, 0)))
      |> Enum.map(fn {k, v} -> " #{k}=\"#{html_attr(v)}\"" end)

  defp normalize_script_attributes(attrs) when is_list(attrs),
    do: Enum.map(attrs, &[" ", to_string(&1)])

  defp maybe_auto_remove(attrs, true), do: attrs ++ [" data-effect=\"el.remove()\""]
  defp maybe_auto_remove(attrs, false), do: attrs

  defp html_attr(value),
    do: value |> to_string() |> String.replace("&", "&amp;") |> String.replace("\"", "&quot;")

  defp present?(value), do: value not in [nil, ""]

  defp parse_accept_encoding(header) do
    header
    |> String.split(",", trim: true)
    |> Enum.map(fn part ->
      [name | params] = part |> String.trim() |> String.split(";", trim: true)

      q =
        Enum.find_value(params, 1.0, fn param ->
          case String.split(String.trim(param), "=", parts: 2) do
            ["q", raw] ->
              case Float.parse(raw) do
                {value, ""} -> value
                _ -> 0.0
              end

            _ ->
              nil
          end
        end)

      {String.downcase(name), q}
    end)
    |> Map.new()
  end

  defp quality(encodings, name, default \\ 0.0),
    do: Map.get(encodings, name, Map.get(encodings, "*", default))
end
