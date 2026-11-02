defmodule AshUi.Datastar.SDKGoldenTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AshUi.Datastar.SDKTestPlug

  @root Path.expand("../fixtures/sdk_golden", __DIR__)

  for method <- ~w(get post), dir <- Path.wildcard(Path.join([@root, method, "*"])) do
    name = Path.basename(dir)
    input = File.read!(Path.join(dir, "input.json"))
    expected = File.read!(Path.join(dir, "output.txt"))

    test "official SDK #{method}/#{name}" do
      conn =
        case unquote(method) do
          "get" ->
            conn(:get, "/test?datastar=" <> URI.encode_www_form(unquote(input)))

          "post" ->
            conn(:post, "/test", unquote(input))
            |> put_req_header("content-type", "application/json")
        end

      response = SDKTestPlug.call(conn, SDKTestPlug.init([]))
      assert response.status == 200
      assert equivalent_sse?(unquote(expected), response.resp_body)
    end
  end

  # Mirrors the official runner: event order is exact, dataline subgroups are
  # compared independently, and element attributes are order-insensitive.
  defp equivalent_sse?(expected, actual) do
    expected = parse_sse(expected)
    actual = parse_sse(actual)

    length(expected) == length(actual) and
      Enum.zip(expected, actual)
      |> Enum.all?(fn {left, right} ->
        left.fields == right.fields and equivalent_data?(left.data, right.data)
      end)
  end

  defp parse_sse(bytes) do
    bytes
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn event ->
      Enum.reduce(String.split(event, "\n", trim: true), %{fields: %{}, data: %{}}, fn line,
                                                                                       acc ->
        case String.split(line, ":", parts: 2) do
          ["data", value] ->
            value = String.trim_leading(value)
            [group | content] = String.split(value, " ", parts: 2)
            content = List.first(content) || ""
            update_in(acc.data[group], fn lines -> (lines || []) ++ [content] end)

          [field, value] ->
            put_in(acc.fields[field], String.trim(value))
        end
      end)
    end)
  end

  defp equivalent_data?(left, right) do
    Map.keys(left) |> Enum.sort() == Map.keys(right) |> Enum.sort() and
      Enum.all?(left, fn
        {"elements", lines} ->
          normalize_html(Enum.join(lines, "\n")) ==
            normalize_html(Enum.join(Map.fetch!(right, "elements"), "\n"))

        {group, lines} ->
          lines == Map.fetch!(right, group)
      end)
  end

  defp normalize_html(html) do
    Regex.replace(~r/<([A-Za-z][A-Za-z0-9-]*)([^>]*)>/, html, fn whole, tag, attrs ->
      if String.trim(attrs) == "" do
        whole
      else
        normalized =
          ~r/[A-Za-z_:][-A-Za-z0-9_:.]*(?:="[^"]*")?/
          |> Regex.scan(attrs)
          |> List.flatten()
          |> Enum.sort()
          |> Enum.join(" ")

        "<" <> tag <> " " <> normalized <> ">"
      end
    end)
  end
end
