defmodule AshUi.Datastar.SSETest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AshUi.Datastar.SSE

  test "patch elements encodes all v1 options and multiline elements" do
    event =
      SSE.patch_elements("<div>\n  <span>x</span>\n</div>",
        selector: "#feed",
        mode: :inner,
        namespace: :svg,
        use_view_transition: true,
        view_transition_selector: "#main",
        event_id: "e1",
        retry_duration: 2_000
      )

    assert SSE.encode(event) ==
             "event: datastar-patch-elements\n" <>
               "id: e1\n" <>
               "retry: 2000\n" <>
               "data: selector #feed\n" <>
               "data: mode inner\n" <>
               "data: namespace svg\n" <>
               "data: useViewTransition true\n" <>
               "data: viewTransitionSelector #main\n" <>
               "data: elements <div>\n" <>
               "data: elements   <span>x</span>\n" <>
               "data: elements </div>\n\n"
  end

  test "patch signals follows merge-patch and multiline dataline format" do
    assert SSE.encode(SSE.patch_signals(%{one: 1}, only_if_missing: true)) ==
             "event: datastar-patch-signals\n" <>
               "data: onlyIfMissing true\n" <>
               "data: signals {\"one\":1}\n\n"

    assert SSE.encode(SSE.patch_signals("{\n\"one\": 1\n}")) ==
             "event: datastar-patch-signals\n" <>
               "data: signals {\n" <>
               "data: signals \"one\": 1\n" <>
               "data: signals }\n\n"
  end

  test "execute script is a body append patch with safe default removal" do
    assert SSE.encode(SSE.execute_script("console.log('x')")) ==
             "event: datastar-patch-elements\n" <>
               "data: selector body\n" <>
               "data: mode append\n" <>
               "data: elements <script data-effect=\"el.remove()\">console.log('x')</script>\n\n"
  end

  test "gzip round trips to identical bytes and synchronously flushes every event" do
    events = [SSE.patch_elements("<div id=\"a\">a</div>"), SSE.patch_signals(%{n: 2})]
    expected = SSE.encode(events)
    {chunks, trailer} = SSE.compressed_chunks(events, :gzip)

    assert length(chunks) == 2
    assert Enum.all?(chunks, &(byte_size(&1) > 0))
    assert byte_size(trailer) > 0
    assert :zlib.gunzip(IO.iodata_to_binary(chunks ++ [trailer])) == expected
  end

  test "negotiation supports gzip q-values and clean identity fallback" do
    assert SSE.negotiate("br, zstd, gzip;q=0.7") == {:ok, :gzip}
    assert SSE.negotiate("br, zstd") == {:ok, :identity}
    assert SSE.negotiate("gzip;q=0, identity;q=0") == {:error, :not_acceptable}
    assert {"connection", "keep-alive"} in SSE.headers(:http1)
    refute Enum.any?(SSE.headers(:http2), &(elem(&1, 0) == "connection"))
  end

  test "the Plug stream negotiates gzip and closes with a decodable trailer" do
    events = [SSE.patch_elements("<div id=\"x\">x</div>"), SSE.patch_signals(%{x: 1})]

    response =
      conn(:get, "/events")
      |> put_req_header("accept-encoding", "br, gzip")
      |> SSE.send_events(events, protocol: :http1)

    assert response.status == 200
    assert get_resp_header(response, "content-encoding") == ["gzip"]
    assert get_resp_header(response, "connection") == ["keep-alive"]
    assert :zlib.gunzip(response.resp_body) == SSE.encode(events)
  end
end
