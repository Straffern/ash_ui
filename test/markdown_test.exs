defmodule AshUi.MarkdownTest do
  use ExUnit.Case, async: true

  alias AshUi.Markdown
  alias AshUi.SafeHTML

  defp html(source), do: source |> Markdown.to_iodata() |> IO.iodata_to_binary()

  describe "constructs render" do
    test "bold" do
      assert html("**Bold**") =~ "<strong>Bold</strong>"
    end

    test "italic" do
      assert html("*soft*") =~ "<em>soft</em>"
    end

    test "code span" do
      assert html("use `mix test` now") =~ "<code>mix test</code>"
    end

    test "fenced code block" do
      out = html("```elixir\nIO.puts(\"hi\")\n```")

      assert out =~ "<pre>"
      assert out =~ "<code>"
      assert out =~ "IO.puts("
      # The language class is stripped: markdown output carries no class attribute.
      refute out =~ "class"
    end

    test "unordered list" do
      out = html("- one\n- two")

      assert out =~ "<ul>"
      assert out =~ "<li>"
      assert out =~ "one"
      assert out =~ "two"
    end

    test "ordered list" do
      assert html("1. first\n2. second") =~ "<ol>"
    end

    test "link keeps href and is given rel" do
      out = html("[docs](https://example.com/a)")

      assert out =~ ~S|<a href="https://example.com/a" rel="noopener noreferrer">|
      assert out =~ "docs</a>"
    end

    test "headings" do
      assert html("# Title") =~ "<h1>Title</h1>"
      assert html("### Small") =~ "<h3>Small</h3>"
    end

    test "blockquote" do
      assert html("> quoted") =~ "<blockquote>"
    end

    test "combined document renders every construct" do
      out =
        html("""
        # Report

        Two items, one **urgent** and one `deferred`:

        - [link](https://example.com)
        - plain

        > note

        ```
        code
        ```
        """)

      for fragment <- [
            "<h1>",
            "<strong>",
            "<code>",
            "<ul>",
            "<li>",
            "<a href=",
            "<blockquote>",
            "<pre>"
          ] do
        assert out =~ fragment, "expected #{fragment} in:\n#{out}"
      end
    end
  end

  describe "plain text is unchanged and escaped" do
    test "plain prose survives with no markup added" do
      assert html("just a sentence") =~ "just a sentence"
    end

    test "text with markdown-significant characters is not mangled into markup" do
      out = html("2 * 3 * 4 = 24")

      refute out =~ "<em>"
      refute out =~ "<strong>"
    end

    test "ampersands and quotes are escaped" do
      out = html(~S|Tom & Jerry said "hi"|)

      assert out =~ "&amp;"
      assert out =~ "&quot;"
    end

    test "blank and nil sources produce nothing" do
      assert html("") == ""
      assert html("   \n  ") == ""
      assert IO.iodata_to_binary(Markdown.to_iodata(nil)) == ""
    end

    test "single newlines inside a paragraph become soft breaks" do
      out = html("first line\nsecond line")

      assert out =~ "first line<br>second line"
    end

    test "no class or style attribute is ever emitted" do
      out =
        html("""
        # Head

        ```elixir
        code
        ```

        - [a](https://example.com)

        > quote
        """)

      refute out =~ ~s(class=)
      refute out =~ ~s(style=)
    end
  end

  describe "raw HTML is escaped, never passed through" do
    test "script tag is inert" do
      out = html("<script>alert(1)</script>")

      refute out =~ "<script"
      assert out =~ "&lt;script&gt;"
      assert out =~ "alert(1)"
    end

    test "inline event handler attribute never survives as markup" do
      out = html(~S|<img src="x" onerror="alert(1)">|)

      refute out =~ "<img"
      refute out =~ ~S|onerror="alert(1)"|
      assert out =~ "&lt;img"
    end

    test "div passthrough is escaped" do
      out = html("<div class='x'>text</div>")

      refute out =~ "<div"
      assert out =~ "&lt;div"
    end

    test "iframe is escaped" do
      out = html(~S|<iframe src="https://evil.test"></iframe>|)

      refute out =~ "<iframe"
      assert out =~ "&lt;iframe"
    end

    test "markdown image syntax does not render an img element" do
      out = html("![alt](https://example.com/x.png)")

      refute out =~ "<img"
    end
  end

  describe "hostile hrefs are neutralized" do
    test "javascript scheme is dropped but link text is kept" do
      out = html("[click](javascript:alert(1))")

      refute out =~ "javascript:"
      refute out =~ "href="
      assert out =~ "click"
      assert out =~ ~s(rel="noopener noreferrer")
    end

    test "uppercase and mixed-case javascript scheme is dropped" do
      refute html("[click](JaVaScRiPt:alert(1))") =~ "href="
    end

    test "tab-obfuscated javascript scheme is dropped" do
      refute html("[click](java\tscript:alert(1))") =~ "href="
    end

    test "data scheme is dropped" do
      refute html("[click](data:text/html;base64,PHNjcmlwdD4=)") =~ "href="
    end

    test "vbscript scheme is dropped" do
      refute html("[click](vbscript:msgbox)") =~ "href="
    end

    test "safe schemes are kept" do
      assert html("[a](https://example.com)") =~ ~S|href="https://example.com"|
      assert html("[a](http://example.com)") =~ ~S|href="http://example.com"|
      assert html("[a](mailto:x@example.com)") =~ ~S|href="mailto:x@example.com"|
    end

    test "relative and anchor hrefs are kept" do
      assert html("[a](/local/path)") =~ ~s(href="/local/path")
      assert html("[a](#section)") =~ ~s(href="#section")
    end

    test "quotes in an href cannot break out of the attribute" do
      out = html(~S|[a](https://example.com/"onmouseover="alert(1))|)

      refute out =~ ~S|onmouseover="alert(1)"|
      assert out =~ "&quot;"
    end
  end

  describe "SafeHTML integration" do
    test "to_safe_html/1 returns a SafeHTML struct carrying the rendered markup" do
      assert %SafeHTML{iodata: iodata} = Markdown.to_safe_html("**hi**")
      assert IO.iodata_to_binary(iodata) =~ "<strong>hi</strong>"
    end

    test "SafeHTML content renders unescaped through the HTML render target" do
      safe = Markdown.to_safe_html("**Bold** and `code`")
      tree = %AshUi.RenderTree.Text{content: safe}

      assert {:safe, iodata} = AshUi.RenderTarget.Html.render_static(tree)
      rendered = IO.iodata_to_binary(iodata)

      assert rendered =~ "<strong>Bold</strong>"
      assert rendered =~ "<code>code</code>"
      refute rendered =~ "&lt;strong&gt;"
    end

    test "a GFM pipe table renders as a table" do
      out = html("| Figure | Relates to |\n|---|---|\n| $4,783.56 | Monthly invoice |")

      assert out =~ "<table><thead><tr><th>Figure</th><th>Relates to</th></tr></thead>"
      assert out =~ "<tbody><tr><td>$4,783.56</td><td>Monthly invoice</td></tr></tbody>"
      assert out =~ "</table>"
    end

    test "table cells still render inline constructs" do
      assert html("| a |\n|---|\n| **bold** |") =~ "<td><strong>bold</strong></td>"
    end

    test "alignment is emitted as data-align, never class or style" do
      out = html("| l | c | r |\n|:---|:-:|---:|\n| 1 | 2 | 3 |")

      assert out =~ ~s(<th>l</th>)
      assert out =~ ~s(<th data-align="center">c</th>)
      assert out =~ ~s(<th data-align="right">r</th>)
      refute out =~ "class"
      refute out =~ "style"
    end

    test "a header row without a delimiter row is not a table" do
      out = html("| a | b |\njust prose")

      refute out =~ "<table"
      assert out =~ "<p>"
    end

    test "prose containing a pipe is left alone" do
      refute html("choose a | b when ready") =~ "<table"
    end

    test "a thematic break is not read as a table delimiter" do
      assert html("---") == "<hr>"
    end

    test "short rows are padded and overflow cells are preserved" do
      out = html("| a | b |\n|---|---|\n| only |\n| x | y | z |")

      assert out =~ "<tr><td>only</td><td></td></tr>"
      assert out =~ "<tr><td>x</td><td>y</td><td>z</td></tr>"
    end

    test "an escaped pipe stays inside its cell" do
      assert html("| a | b |\n|---|---|\n| x \\| y | z |") =~ "<td>x | y</td>"
    end

    test "table cell content is escaped" do
      out = html("| a |\n|---|\n| <script>alert(1)</script> |")

      refute out =~ "<script"
      assert out =~ "&lt;script&gt;"
    end

    test "a table ends at a blank line and later blocks still render" do
      out = html("| a |\n|---|\n| 1 |\n\n# After")

      assert out =~ "</table>"
      assert out =~ "<h1>After</h1>"
    end

    test "split_tables isolates table blocks and round-trips the source" do
      source = "intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter"
      parts = Markdown.split_tables(source)

      assert [{:prose, _}, {:table, table}, {:prose, _}] = parts
      assert table == "| a | b |\n|---|---|\n| 1 | 2 |"
      assert parts |> Enum.map_join("\n", fn {_kind, text} -> text end) == source
    end

    test "split_tables returns a single prose run when there is no table" do
      assert [{:prose, "just words"}] = Markdown.split_tables("just words")
    end

    test "split_tables handles back-to-back tables" do
      source = "| a |\n|---|\n| 1 |\n\n| b |\n|---|\n| 2 |"
      parts = Markdown.split_tables(source)

      assert Enum.count(parts, &(elem(&1, 0) == :table)) == 2
      assert parts |> Enum.map_join("\n", fn {_kind, text} -> text end) == source
    end

    test "parse_table exposes the same cells and alignments for structural renderers" do
      source = "| left | centered |\n|---|:-:|\n| **one** | x \\| y |"

      assert {:ok,
              %{
                headers: [
                  %{text: "left", alignment: :none},
                  %{text: "centered", alignment: :center}
                ],
                rows: [
                  [
                    %{text: "**one**", alignment: :none},
                    %{text: "x | y", alignment: :center}
                  ]
                ]
              }} = Markdown.parse_table(source)

      assert %SafeHTML{iodata: inline} = Markdown.to_safe_inline_html("**one**")
      assert IO.iodata_to_binary(inline) == "<strong>one</strong>"
    end

    test "table rows retain cells beyond the header width on both render paths" do
      source = """
      | Header |
      | --- |
      | first | second | final overflow |
      """

      rendered = html(source)

      assert rendered =~ "<td>first</td><td>second</td><td>final overflow</td>"

      assert {:ok, %{rows: [row]}} = Markdown.parse_table(String.trim(source))
      assert Enum.map(row, & &1.text) == ["first", "second", "final overflow"]
    end

    test "a hostile body stays inert all the way through the render target" do
      safe = Markdown.to_safe_html("<script>alert(1)</script> and [x](javascript:alert(2))")
      tree = %AshUi.RenderTree.Text{content: safe}

      assert {:safe, iodata} = AshUi.RenderTarget.Html.render_static(tree)
      rendered = IO.iodata_to_binary(iodata)

      refute rendered =~ "<script"
      refute rendered =~ "javascript:"
      assert rendered =~ "&lt;script&gt;"
    end
  end
end
