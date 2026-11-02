defmodule AshUi.Markdown do
  @moduledoc """
  Markdown source -> sanitized `AshUi.SafeHTML`.

  This is the single shared markdown seam for AshUi views. It lives beside
  `AshUi.SafeHTML` because SafeHTML is the only sanctioned way to put
  non-escaped markup into a render tree: the constructor vocabulary is closed
  (`AshUi.ViewConstructor`), so a view keeps emitting an ordinary
  `text(...)` node and instead changes what that expression *evaluates to*.

  Callers build the value where the row is built (a calculation), never in the
  view:

      calculate :body_html, :term, fn records, _context ->
        Enum.map(records, &AshUi.Markdown.to_safe_html(&1.plain_text))
      end

  ## Why this is self-contained

  Rendering is done here rather than through a markdown library because adding
  any dependency to this package forces Mix to re-resolve and bump unrelated
  transitive pins. The supported syntax is deliberately a small, chat-shaped
  subset, which is tractable to render directly and keeps the package
  dependency-free.

  Supported: paragraphs, `#`..`######` headings, `**bold**`/`__bold__`,
  `*italic*`/`_italic_`, `~~strikethrough~~`, `` `code spans` ``, fenced code
  blocks, unordered (`-`/`*`/`+`) and ordered (`1.`) lists, `>` blockquotes,
  thematic breaks, GFM pipe tables, and `[text](href)` links. Single newlines
  inside a paragraph become `<br>`, which matches how chat bodies are written.

  A table is recognised only when a header row is followed immediately by a
  delimiter row (`|---|:-:|--:|`), so ordinary prose containing a `|` is never
  mistaken for one. Rows are padded or truncated to the header's column count,
  so a ragged row cannot shift later cells into the wrong column.

  ## Sanitization

  `SafeHTML` means "emit these bytes verbatim" and performs no escaping of its
  own, so everything here is whitelisted by construction rather than filtered
  after the fact. Message bodies are user input and assistant replies are model
  output; neither is trusted.

    * Only the tags this module writes are ever emitted -- there is no path from
      source text to an arbitrary tag name.
    * Every run of text is escaped through
      `AshUi.RenderTarget.Html.html_escape/1`, so raw HTML in the source
      is inert: a user who types `<script>alert(1)</script>` sees that text.
    * The only attributes ever emitted are `href` and `rel` on `<a>`, and
      `data-align` on a table cell, whose value is drawn from the closed set
      `center`/`right` rather than from the source.
    * `href` is scheme-checked against `@safe_schemes` after control characters
      are stripped, so `javascript:`, `data:`, `vbscript:` and obfuscations such
      as `java&#9;script:` are dropped, leaving a plain `<a>` with no href.
    * Every `<a>` carries `rel="noopener noreferrer"`.
    * Images never render: `![alt](src)` degrades to its alt text.

  No `class` or `style` attribute is ever emitted -- markdown output is painted
  by descendant-element CSS under the owning `[part=...]` node, matching the
  existing `[part="agent_markdown"] code` rule.
  """

  alias AshUi.RenderTarget.Html
  alias AshUi.SafeHTML

  @safe_schemes ~w(http https mailto)

  @fence ~r/^\s{0,3}(`{3,}|~{3,})\s*([^\s`]*)\s*$/
  @heading ~r/^\s{0,3}(\#{1,6})\s+(.*?)\s*\#*\s*$/
  @thematic_break ~r/^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/
  @bullet ~r/^\s{0,3}[-*+]\s+(.*)$/
  @ordered ~r/^\s{0,3}\d{1,9}[.)]\s+(.*)$/
  @quote ~r/^\s{0,3}>\s?(.*)$/
  # A GFM table row is any line containing a `|` outside the leading indent;
  # a table only starts when the *next* line is a delimiter row, so ordinary
  # prose containing a pipe is never mistaken for one.
  @table_row ~r/^\s{0,3}\S*\|/
  @table_delimiter ~r/^\s{0,3}\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/

  @doc """
  Renders markdown `source` into a sanitized `AshUi.SafeHTML` struct,
  suitable as the text content of a render-tree node.
  """
  @spec to_safe_html(term()) :: SafeHTML.t()
  def to_safe_html(source), do: SafeHTML.new(to_iodata(source))

  @doc """
  Renders markdown inline syntax without adding a block wrapper.

  This is intended for structural consumers such as table cells that still
  need AshUi-owned interactive children between formatted text runs.
  """
  @spec to_safe_inline_html(term()) :: SafeHTML.t()
  def to_safe_inline_html(nil), do: SafeHTML.new("")
  def to_safe_inline_html(source) when is_binary(source), do: SafeHTML.new(inline(source))
  def to_safe_inline_html(source), do: source |> to_string() |> to_safe_inline_html()

  @doc """
  Renders markdown `source` into sanitized HTML iodata.
  """
  @spec to_iodata(term()) :: iodata()
  def to_iodata(nil), do: []

  def to_iodata(source) when is_binary(source) do
    if String.trim(source) == "" do
      []
    else
      source
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> blocks()
    end
  end

  def to_iodata(source), do: to_iodata(to_string(source))

  @doc """
  Splits `source` into consecutive `{:table, text}` and `{:prose, text}` runs.

  Table syntax is known only to this module, so callers that must treat a table
  as an indivisible unit ask here rather than re-deriving the grammar. Structural
  consumers can then pass each table block to `parse_table/1` and keep
  interactive children inside their owning cells.

  Concatenating the returned texts reproduces `source` exactly.
  """
  @spec split_tables(term()) :: [{:table | :prose, binary()}]
  def split_tables(nil), do: []

  def split_tables(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> split_tables([], [])
  end

  def split_tables(source), do: source |> to_string() |> split_tables()

  @doc """
  Parses one GFM pipe-table block into raw cell text and closed alignments.

  Callers can then render the table with ordinary AshUi table/cell nodes,
  preserving interactive content inside cells without reimplementing the
  markdown table grammar.
  """
  @spec parse_table(term()) ::
          {:ok, %{headers: [map()], rows: [[map()]]}} | {:error, :not_a_table}
  def parse_table(source) when is_binary(source) do
    case String.split(source, "\n") do
      [header, delimiter | rows] ->
        if table_start?(header, [delimiter]) and
             Enum.all?(rows, &(String.trim(&1) != "" and Regex.match?(@table_row, &1))) do
          headers = split_row(header)
          alignments = Enum.map(split_row(delimiter), &alignment/1)
          width = length(headers)

          cell = fn text, index ->
            %{text: text, alignment: Enum.at(alignments, index, :none)}
          end

          {:ok,
           %{
             headers:
               headers
               |> pad(width)
               |> Enum.with_index()
               |> Enum.map(fn {text, index} -> cell.(text, index) end),
             rows:
               Enum.map(rows, fn row ->
                 row
                 |> split_row()
                 |> pad(width)
                 |> Enum.with_index()
                 |> Enum.map(fn {text, index} -> cell.(text, index) end)
               end)
           }}
        else
          {:error, :not_a_table}
        end

      _not_table ->
        {:error, :not_a_table}
    end
  end

  def parse_table(_source), do: {:error, :not_a_table}

  defp split_tables([], prose, acc), do: Enum.reverse(emit_prose(prose, acc))

  defp split_tables([line | rest], prose, acc) do
    if table_start?(line, rest) do
      [delimiter | body] = rest
      {rows, remainder} = take_table_rows(body, [])
      table = Enum.join([line, delimiter | rows], "\n")
      split_tables(remainder, [], [{:table, table} | emit_prose(prose, acc)])
    else
      split_tables(rest, [line | prose], acc)
    end
  end

  defp emit_prose([], acc), do: acc
  defp emit_prose(prose, acc), do: [{:prose, prose |> Enum.reverse() |> Enum.join("\n")} | acc]

  # -- block level ----------------------------------------------------------

  defp blocks(lines), do: blocks(lines, [])

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | rest], acc) do
    cond do
      String.trim(line) == "" ->
        blocks(rest, acc)

      match = Regex.run(@fence, line) ->
        [_, delimiter, _info] = match
        {code, remainder} = take_fenced(rest, String.first(delimiter), [])
        blocks(remainder, [["<pre><code>", Html.html_escape(code), "</code></pre>"] | acc])

      match = Regex.run(@thematic_break, line) ->
        _ = match
        blocks(rest, ["<hr>" | acc])

      match = Regex.run(@heading, line) ->
        [_, hashes, body] = match
        tag = "h#{String.length(hashes)}"
        blocks(rest, [["<", tag, ">", inline(body), "</", tag, ">"] | acc])

      Regex.match?(@bullet, line) ->
        {items, remainder} = take_matching([line | rest], @bullet, [])

        blocks(remainder, [
          ["<ul>", Enum.map(items, &["<li>", inline(&1), "</li>"]), "</ul>"] | acc
        ])

      Regex.match?(@ordered, line) ->
        {items, remainder} = take_matching([line | rest], @ordered, [])

        blocks(remainder, [
          ["<ol>", Enum.map(items, &["<li>", inline(&1), "</li>"]), "</ol>"] | acc
        ])

      Regex.match?(@quote, line) ->
        {quoted, remainder} = take_matching([line | rest], @quote, [])
        blocks(remainder, [["<blockquote>", blocks(quoted), "</blockquote>"] | acc])

      table_start?(line, rest) ->
        [delimiter | body] = rest
        {rows, remainder} = take_table_rows(body, [])
        blocks(remainder, [table(line, delimiter, rows) | acc])

      true ->
        {paragraph, remainder} = take_paragraph([line | rest], [])
        blocks(remainder, [["<p>", paragraph, "</p>"] | acc])
    end
  end

  defp take_fenced([], _delimiter, acc), do: {joined(acc), []}

  defp take_fenced([line | rest], delimiter, acc) do
    case Regex.run(@fence, line) do
      [_, closing, _info] ->
        if String.first(closing) == delimiter do
          {joined(acc), rest}
        else
          take_fenced(rest, delimiter, [line | acc])
        end

      _no_match ->
        take_fenced(rest, delimiter, [line | acc])
    end
  end

  defp take_matching([line | rest] = lines, regex, acc) do
    case Regex.run(regex, line) do
      [_, body] -> take_matching(rest, regex, [body | acc])
      _no_match -> {Enum.reverse(acc), lines}
    end
  end

  defp take_matching([], _regex, acc), do: {Enum.reverse(acc), []}

  # -- tables ---------------------------------------------------------------
  #
  # GFM pipe tables. A table is only recognised when a header row is followed
  # immediately by a delimiter row, which is what keeps prose containing a `|`
  # from being swallowed. Short rows are padded to the header width; longer
  # rows retain every overflow cell instead of silently discarding content.

  defp table_start?(line, [delimiter | _rest]) do
    Regex.match?(@table_row, line) and Regex.match?(@table_delimiter, delimiter) and
      not Regex.match?(@thematic_break, line)
  end

  defp table_start?(_line, []), do: false

  defp take_table_rows([line | rest] = lines, acc) do
    if String.trim(line) != "" and Regex.match?(@table_row, line) do
      take_table_rows(rest, [line | acc])
    else
      {Enum.reverse(acc), lines}
    end
  end

  defp take_table_rows([], acc), do: {Enum.reverse(acc), []}

  defp table(header_line, delimiter_line, row_lines) do
    headers = split_row(header_line)
    alignments = Enum.map(split_row(delimiter_line), &alignment/1)
    width = length(headers)

    [
      "<table><thead><tr>",
      cells(headers, alignments, width, "th"),
      "</tr></thead>",
      body_rows(row_lines, alignments, width),
      "</table>"
    ]
  end

  defp body_rows([], _alignments, _width), do: []

  defp body_rows(row_lines, alignments, width) do
    [
      "<tbody>",
      Enum.map(row_lines, fn row ->
        ["<tr>", cells(split_row(row), alignments, width, "td"), "</tr>"]
      end),
      "</tbody>"
    ]
  end

  defp cells(values, alignments, width, tag) do
    values
    |> pad(width)
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      ["<", tag, align_attribute(Enum.at(alignments, index)), ">", inline(value), "</", tag, ">"]
    end)
  end

  defp pad(values, width) when length(values) >= width, do: values
  defp pad(values, width), do: values ++ List.duplicate("", width - length(values))

  # Alignment is emitted as `data-align` with a closed value set rather than a
  # `style`/`class`/`align` attribute, so paint stays in the theme stylesheet
  # and the "no arbitrary attributes" guarantee above still holds.
  defp align_attribute(:center), do: ~s( data-align="center")
  defp align_attribute(:right), do: ~s( data-align="right")
  defp align_attribute(_none), do: ""

  defp alignment(spec) do
    trimmed = String.trim(spec)
    left? = String.starts_with?(trimmed, ":")
    right? = String.ends_with?(trimmed, ":")

    cond do
      left? and right? -> :center
      right? -> :right
      true -> :none
    end
  end

  # `a|b\|c` -> ["a", "b|c"]: an escaped pipe is a literal cell character.
  defp split_row(line) do
    line
    |> String.trim()
    |> String.replace(~r/^\|/, "")
    |> String.replace(~r/\|$/, "")
    |> String.split(~r/(?<!\\)\|/)
    |> Enum.map(&(&1 |> String.replace("\\|", "|") |> String.trim()))
  end

  # A paragraph runs to the first blank line or the first line that opens
  # another block, so `text` immediately followed by `- item` still splits.
  defp take_paragraph([], acc), do: {intersperse_breaks(acc), []}

  defp take_paragraph([line | rest] = lines, acc) do
    if String.trim(line) == "" or block_start?(line, rest) do
      {intersperse_breaks(acc), lines}
    else
      take_paragraph(rest, [line | acc])
    end
  end

  defp block_start?(line, rest) do
    Regex.match?(@fence, line) or Regex.match?(@thematic_break, line) or
      Regex.match?(@heading, line) or Regex.match?(@bullet, line) or
      Regex.match?(@ordered, line) or Regex.match?(@quote, line) or
      table_start?(line, rest)
  end

  defp intersperse_breaks(reversed_lines) do
    reversed_lines
    |> Enum.reverse()
    |> Enum.map(&inline/1)
    |> Enum.intersperse("<br>")
  end

  defp joined(reversed_lines), do: reversed_lines |> Enum.reverse() |> Enum.join("\n")

  # -- inline level ---------------------------------------------------------

  # Ordered by precedence. Code spans come first so their contents are never
  # reinterpreted as emphasis. Emphasis delimiters require a non-space on the
  # inner side, so `2 * 3 * 4` is arithmetic rather than emphasis.
  @inline_patterns [
    {:code, ~r/`([^`\n]+)`/},
    {:image, ~r/!\[([^\]\n]*)\]\(([^)\s]*)\)/},
    {:link, ~r/\[([^\]\n]*)\]\(([^)\s]*)\)/},
    {:strong, ~r/\*\*(?!\s)((?:[^*]|\*(?!\*))+?)(?<!\s)\*\*/},
    {:strong, ~r/(?<![a-zA-Z0-9_])__(?!\s)(.+?)(?<!\s)__(?![a-zA-Z0-9_])/},
    {:del, ~r/~~(?!\s)(.+?)(?<!\s)~~/},
    {:em, ~r/\*(?!\s)([^*\n]+?)(?<!\s)\*/},
    {:em, ~r/(?<![a-zA-Z0-9_])_(?!\s)([^_\n]+?)(?<!\s)_(?![a-zA-Z0-9_])/}
  ]

  defp inline(""), do: []

  defp inline(text) do
    case earliest_match(text) do
      nil ->
        Html.html_escape(text)

      {kind, index, length, captures} ->
        prefix = binary_part(text, 0, index)
        rest = binary_part(text, index + length, byte_size(text) - index - length)

        [Html.html_escape(prefix), render_inline(kind, captures), inline(rest)]
    end
  end

  defp earliest_match(text) do
    @inline_patterns
    |> Enum.reduce(nil, fn {kind, regex}, best ->
      case Regex.run(regex, text, return: :index, capture: :all) do
        nil ->
          best

        [{index, length} | capture_positions] ->
          candidate =
            {kind, index, length, Enum.map(capture_positions, &capture_text(text, &1))}

          case best do
            nil -> candidate
            {_kind, best_index, _length, _captures} when index < best_index -> candidate
            _other -> best
          end
      end
    end)
  end

  defp capture_text(_text, {-1, _length}), do: ""
  defp capture_text(text, {index, length}), do: binary_part(text, index, length)

  defp render_inline(:code, [content]), do: ["<code>", Html.html_escape(content), "</code>"]
  defp render_inline(:strong, [content]), do: ["<strong>", inline(content), "</strong>"]
  defp render_inline(:em, [content]), do: ["<em>", inline(content), "</em>"]
  defp render_inline(:del, [content]), do: ["<del>", inline(content), "</del>"]

  # Images degrade to their alt text: no <img> is ever emitted.
  defp render_inline(:image, [alt, _src]), do: Html.html_escape(alt)

  defp render_inline(:link, [label, href]) do
    case sanitize_href(href) do
      nil ->
        [~s(<a rel="noopener noreferrer">), inline(label), "</a>"]

      safe ->
        [
          ~s(<a href="),
          Html.html_escape(safe),
          ~s(" rel="noopener noreferrer">),
          inline(label),
          "</a>"
        ]
    end
  end

  # -- href policy ----------------------------------------------------------

  defp sanitize_href(value) when is_binary(value) do
    trimmed = String.trim(value)

    # Control characters and whitespace are stripped before the scheme check so
    # that `java&#9;script:` style obfuscations cannot smuggle a scheme past it.
    normalized =
      trimmed
      |> String.replace(~r/[\x00-\x20]/, "")
      |> String.downcase()

    cond do
      normalized == "" -> nil
      String.starts_with?(normalized, "#") -> trimmed
      String.starts_with?(normalized, "/") -> trimmed
      is_nil(scheme(normalized)) -> trimmed
      scheme(normalized) in @safe_schemes -> trimmed
      true -> nil
    end
  end

  defp sanitize_href(_value), do: nil

  defp scheme(normalized) do
    case String.split(normalized, ":", parts: 2) do
      [candidate, _rest] ->
        if Regex.match?(~r/^[a-z][a-z0-9+.\-]*$/, candidate), do: candidate, else: nil

      _other ->
        nil
    end
  end
end
