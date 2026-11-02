defmodule AshUi.Verifiers.StylesheetCoverage do
  @moduledoc """
  Compile-time `[part=]` coverage over a document root's render closure
  (DESIGN.md §9).

  Every part emitted by a routed resource's view — including everything it
  transitively `render()`s — must match a `[part=...]` rule in the resource's
  effective stylesheets. The extractor is a comment- and string-aware SCANNER,
  not a CSS engine: `[part="x"]`, `[part='x']`, and `[part=x]` are matched
  literally.

  Also enforced here:

  - `@import` anywhere in a declared sheet is a compile error — the
    `stylesheets` list is the sole import order.
  - Every declared sheet must exist as a readable file at compile time
    (paths resolve relative to the compiling project's root).
  """

  use Spark.Dsl.Verifier

  alias AshUi.Verifiers.Helpers
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    effective = Verifier.get_persisted(dsl_state, :ash_ui_stylesheets, []) || []

    if routed?(dsl_state) and effective != [] do
      verify_sheets(dsl_state, effective)
    else
      # Missing stylesheets on a routed resource is StylesheetResolution's
      # teaching error; components have nothing to cover here.
      :ok
    end
  end

  defp routed?(dsl_state) do
    case Verifier.get_persisted(dsl_state, :ash_ui_declared_routes, []) do
      routes when is_list(routes) -> routes != []
      _other -> false
    end
  end

  defp verify_sheets(dsl_state, stylesheets) do
    root = File.cwd!()

    with {:ok, sheets} <- read_sheets(dsl_state, stylesheets, root),
         :ok <- reject_imports(dsl_state, sheets) do
      verify_coverage(dsl_state, sheets)
    end
  end

  defp read_sheets(dsl_state, stylesheets, root) do
    stylesheets
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      abs = Path.expand(path, root)

      case File.read(abs) do
        {:ok, css} ->
          {:cont, {:ok, [%{path: path, abs: abs, css: css, scan: scan_css(css)} | acc]}}

        {:error, reason} ->
          {:halt,
           {:error,
            Helpers.dsl_error(
              dsl_state,
              [:ash_ui, :stylesheets],
              missing_sheet_message(path, abs, reason)
            )}}
      end
    end)
    |> case do
      {:ok, sheets} -> {:ok, Enum.reverse(sheets)}
      error -> error
    end
  end

  defp reject_imports(dsl_state, sheets) do
    sheets
    |> Enum.flat_map(fn sheet ->
      sheet.scan
      |> Map.fetch!(:imports)
      |> Enum.map(&{sheet.path, &1})
    end)
    |> case do
      [] ->
        :ok

      imports ->
        {:error,
         Helpers.dsl_error(
           dsl_state,
           [:ash_ui, :stylesheets],
           import_message(imports)
         )}
    end
  end

  defp verify_coverage(dsl_state, sheets) do
    covered =
      Enum.reduce(sheets, MapSet.new(), fn sheet, acc ->
        sheet.scan |> Map.fetch!(:parts) |> MapSet.union(acc)
      end)

    emitted =
      dsl_state
      |> Helpers.compiled_resource!()
      |> closure_parts()

    uncovered =
      emitted
      |> MapSet.reject(&MapSet.member?(covered, &1))
      |> Enum.sort()

    if uncovered == [] do
      :ok
    else
      {:error,
       Helpers.dsl_error(
         dsl_state,
         [:ash_ui, :stylesheets],
         uncovered_message(uncovered, Enum.map(sheets, & &1.path))
       )}
    end
  end

  # ---------------------------------------------------------------------------
  # Emitted-part collection over the render closure.
  #
  # Mirrors the HTML target's part inference exactly (RenderTarget.Html
  # inferred_part/2): authored part, else meta node/semantic name, else the
  # element's tag. Only statically-known names participate; VerifyExpressions
  # rejects dynamic authored parts before they can evade this coverage scan.
  # ---------------------------------------------------------------------------

  @doc false
  def closure_parts(resource) do
    {parts, _visited} = collect_node(resource.view, MapSet.new(), MapSet.new())
    parts
  end

  defp collect_node(nil, parts, visited), do: {parts, visited}

  defp collect_node(%{kind: :element} = node, parts, visited) do
    parts =
      case element_part(node) do
        nil -> parts
        part -> MapSet.put(parts, to_string(part))
      end

    collect_children(node, parts, visited)
  end

  defp collect_node(%{kind: kind} = node, parts, visited) when kind in [:stack, :row] do
    collect_children(node, MapSet.put(parts, to_string(kind)), visited)
  end

  defp collect_node(%{kind: :resource_component, resource: child} = node, parts, visited)
       when is_atom(child) do
    {parts, visited} =
      node
      |> Map.get(:assigns, %{})
      |> assigns_values()
      |> Enum.reduce({parts, visited}, fn value, {parts, visited} ->
        collect_assign_value(value, parts, visited)
      end)

    if MapSet.member?(visited, child) do
      {parts, visited}
    else
      visited = MapSet.put(visited, child)
      child_resource = AshUi.Compiled.resource!(child)
      collect_node(child_resource.view, parts, visited)
    end
  end

  defp collect_node(%{kind: :if} = node, parts, visited) do
    {parts, visited} = collect_node(Map.get(node, :then), parts, visited)
    collect_node(Map.get(node, :else), parts, visited)
  end

  defp collect_node(%{child: child} = node, parts, visited) do
    {parts, visited} = collect_children(node, parts, visited)
    collect_node(child, parts, visited)
  end

  defp collect_node(%{children: _children} = node, parts, visited) do
    collect_children(node, parts, visited)
  end

  defp collect_node(_node, parts, visited), do: {parts, visited}

  defp collect_children(node, parts, visited) do
    node
    |> Map.get(:children, [])
    |> List.wrap()
    |> Enum.reduce({parts, visited}, fn child, {parts, visited} ->
      collect_node(child, parts, visited)
    end)
  end

  defp assigns_values(assigns) when is_map(assigns), do: Map.values(assigns)

  defp assigns_values(assigns) when is_list(assigns) do
    Enum.map(assigns, fn
      %{from: value} -> value
      {_key, value} -> value
      other -> other
    end)
  end

  defp assigns_values(_other), do: []

  defp collect_assign_value(%{kind: _kind} = node, parts, visited),
    do: collect_node(node, parts, visited)

  defp collect_assign_value(values, parts, visited) when is_list(values) do
    Enum.reduce(values, {parts, visited}, fn value, {parts, visited} ->
      collect_assign_value(value, parts, visited)
    end)
  end

  defp collect_assign_value(_value, parts, visited), do: {parts, visited}

  defp element_part(%{kind: :element} = node) do
    meta = Map.get(node, :meta) || %{}

    static_name(Map.get(node, :part)) ||
      static_name(Map.get(meta, :component_part)) ||
      static_name(Map.get(meta, :node)) ||
      static_name(semantic_name(meta)) ||
      static_name(Map.get(node, :tag))
  end

  defp semantic_name(%{semantic: {_kind, name}}), do: name
  defp semantic_name(_meta), do: nil

  defp static_name(name) when is_atom(name) and not is_nil(name), do: name
  defp static_name(name) when is_binary(name), do: name
  defp static_name(_other), do: nil

  # ---------------------------------------------------------------------------
  # Comment/string-aware CSS scanner. Not a CSS engine: extracts literal
  # [part="x"] / [part='x'] / [part=x] selector names and @import positions.
  # ---------------------------------------------------------------------------

  @doc false
  def scan_css(css) when is_binary(css) do
    scan(css, 1, %{parts: MapSet.new(), imports: []})
    |> Map.update!(:imports, &Enum.reverse/1)
  end

  defp scan(<<>>, _line, acc), do: acc

  defp scan(<<"/*", rest::binary>>, line, acc) do
    {rest, line} = skip_comment(rest, line)
    scan(rest, line, acc)
  end

  defp scan(<<quote, rest::binary>>, line, acc) when quote in [?", ?'] do
    {rest, line, _value} = take_string(rest, quote, line, [])
    scan(rest, line, acc)
  end

  defp scan(<<"@", rest::binary>>, line, acc) do
    case take_import_keyword(rest) do
      {:ok, <<>>} ->
        scan(<<>>, line, Map.update!(acc, :imports, &[line | &1]))

      {:ok, <<next, _::binary>> = rest} ->
        if css_ident_continue?(next) do
          scan(rest, line, acc)
        else
          scan(rest, line, Map.update!(acc, :imports, &[line | &1]))
        end

      :error ->
        scan(rest, line, acc)
    end
  end

  defp scan(<<"[", rest::binary>>, line, acc) do
    case take_part_selector(rest, line) do
      {:ok, part, rest, line} -> scan(rest, line, Map.update!(acc, :parts, &MapSet.put(&1, part)))
      :error -> scan(rest, line, acc)
    end
  end

  defp scan(<<?\n, rest::binary>>, line, acc), do: scan(rest, line + 1, acc)
  defp scan(<<_char, rest::binary>>, line, acc), do: scan(rest, line, acc)

  defp take_import_keyword(<<i, m, p, o, r, t, rest::binary>>)
       when i in [?i, ?I] and m in [?m, ?M] and p in [?p, ?P] and o in [?o, ?O] and
              r in [?r, ?R] and t in [?t, ?T],
       do: {:ok, rest}

  defp take_import_keyword(_rest), do: :error

  defp css_ident_continue?(char),
    do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?-, ?_]

  defp skip_comment(<<"*/", rest::binary>>, line), do: {rest, line}
  defp skip_comment(<<?\n, rest::binary>>, line), do: skip_comment(rest, line + 1)
  defp skip_comment(<<_char, rest::binary>>, line), do: skip_comment(rest, line)
  defp skip_comment(<<>>, line), do: {<<>>, line}

  defp take_string(<<?\\, char, rest::binary>>, quote, line, value) do
    take_string(rest, quote, line, [value, ?\\, char])
  end

  defp take_string(<<quote, rest::binary>>, quote, line, value) do
    {rest, line, IO.iodata_to_binary(value)}
  end

  defp take_string(<<?\n, rest::binary>>, quote, line, value) do
    take_string(rest, quote, line + 1, [value, ?\n])
  end

  defp take_string(<<char, rest::binary>>, quote, line, value) do
    take_string(rest, quote, line, [value, char])
  end

  defp take_string(<<>>, _quote, line, value), do: {<<>>, line, IO.iodata_to_binary(value)}

  defp take_part_selector(rest, line) do
    with {rest, line} <- skip_ws(rest, line),
         <<"part", rest::binary>> <- rest,
         {rest, line} <- skip_ws(rest, line),
         <<"=", rest::binary>> <- rest,
         {rest, line} <- skip_ws(rest, line),
         {:ok, part, rest, line} <- take_attr_value(rest, line) do
      {:ok, part, rest, line}
    else
      _other -> :error
    end
  end

  defp skip_ws(<<?\n, rest::binary>>, line), do: skip_ws(rest, line + 1)
  defp skip_ws(<<char, rest::binary>>, line) when char in [?\s, ?\t, ?\r], do: skip_ws(rest, line)
  defp skip_ws(rest, line), do: {rest, line}

  defp take_attr_value(<<quote, rest::binary>>, line) when quote in [?", ?'] do
    {rest, line, value} = take_string(rest, quote, line, [])
    {:ok, value, rest, line}
  end

  defp take_attr_value(rest, line), do: take_bare_value(rest, line, [])

  defp take_bare_value(<<char, rest::binary>>, line, value)
       when char not in [?\], ?\s, ?\t, ?\n, ?\r] do
    take_bare_value(rest, line, [value, char])
  end

  defp take_bare_value(rest, line, value) do
    case IO.iodata_to_binary(value) do
      "" -> :error
      part -> {:ok, part, rest, line}
    end
  end

  # ---------------------------------------------------------------------------
  # Teaching errors
  # ---------------------------------------------------------------------------

  defp missing_sheet_message(path, abs, reason) do
    """
    Declared stylesheet #{inspect(path)} does not exist or is unreadable
    (#{inspect(reason)} at #{abs}).

    Every declared stylesheet is a compile-time build input: part coverage is
    verified against its [part=...] rules, so the file must exist as a
    readable file when the resources declaring it compile. A generated sheet
    must be generated BEFORE those resources compile.

    Create the file (or fix the path — entries resolve relative to the
    project root of the declaring resource):

        ash_ui do
          stylesheets ["assets/css/theme.css", "assets/css/app.css"]
        end

    See the ash_ui DESIGN.md §9.\
    """
  end

  defp import_message(imports) do
    listing =
      Enum.map_join(imports, "\n", fn {path, line} -> "    #{path}:#{line}" end)

    """
    A declared stylesheet uses @import:

    #{listing}

    The `stylesheets` list is the SOLE import order — a hidden @import is a
    second assembly channel the framework cannot verify or order. Inline the
    imported rules, or declare the imported file as its own entry in the
    order you want it linked:

        ash_ui do
          stylesheets ["assets/css/theme.css", "assets/css/app.css"]
        end

    See the ash_ui DESIGN.md §9.\
    """
  end

  defp uncovered_message(uncovered, scanned) do
    """
    This routed AshUi resource emits parts with no [part=...] rule in its
    effective stylesheets.

    Coverage is the compile-time contract that every semantic hook the render
    closure emits (this page and everything it render()s) has declared paint —
    an uncovered part is invisible styling debt that would only surface in the
    browser.

    Uncovered parts (#{length(uncovered)}):

    #{Enum.map_join(uncovered, "\n", &("    " <> &1))}

    Stylesheets scanned:

    #{Enum.map_join(scanned, "\n", &("    " <> &1))}

    Add a rule per part to one of the declared sheets (grouped selectors are
    fine):

        [part="#{List.first(uncovered)}"] { /* paint */ }

        /* or grouped: */
        :where([part="a"], [part="b"]) { /* shared paint */ }

    See the ash_ui DESIGN.md §9.\
    """
  end
end
