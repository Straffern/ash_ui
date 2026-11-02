defmodule AshUi.Theme.VSCode do
  @moduledoc """
  Build-side stylesheet GENERATOR for VS Code color-theme JSON (DESIGN.md §9).

  Theme JSON goes in, CSS text comes out: VS Code webview-compatible custom
  properties (`--vscode-*`), a small `[part=...]` mapping for VS Code-style lists, side bars, panels and inputs, and
  TextMate scope CSS. WCAG contrast gates apply at generation time.

  This module does not participate in rendering. Write the generated CSS to a
  file BEFORE the resources declaring it compile, then declare it like any
  stylesheet:

      css = AshUi.Theme.VSCode.stylesheet_from_file!("priv/themes/dark.json")
      File.write!("assets/css/theme.css", css)

      ash_ui do
        stylesheets ["assets/css/theme.css", "assets/css/app.css"]
      end
  """

  import Bitwise, only: [band: 2, >>>: 2]

  @contrast_threshold 4.5
  @contrast_pairs [
    {"editor.foreground", "editor.background", "editor"},
    {"sideBar.foreground", "sideBar.background", "side bar"},
    {"panel.foreground", "panel.background", "panel"},
    {"quickInput.foreground", "quickInput.background", "quick input"},
    {"input.foreground", "input.background", "input"},
    {"button.foreground", "button.background", "button"},
    {"button.secondaryForeground", "button.secondaryBackground", "secondary button"},
    {"list.activeSelectionForeground", "list.activeSelectionBackground", "active list row"},
    {"list.inactiveSelectionForeground", "list.inactiveSelectionBackground", "inactive list row"},
    {"list.hoverForeground", "list.hoverBackground", "hover list row"},
    {"badge.foreground", "badge.background", "badge"}
  ]

  @generic_tokens [
    {"surface", "editor.background"},
    {"surface-panel", "panel.background"},
    {"surface-sidebar", "sideBar.background"},
    {"surface-input", "input.background"},
    {"ink", "editor.foreground"},
    {"ink-muted", "descriptionForeground"},
    {"accent", "focusBorder"},
    {"accent-ink", "button.foreground"},
    {"border", "panel.border"},
    {"radius", "cornerRadius.small"}
  ]

  @workbench_parts [
    {"list", ".workbench-list",
     [
       {"background-color", "list.inactiveSelectionBackground", "sideBar.background"},
       {"color", "list.inactiveSelectionForeground", "foreground"},
       {"border-color", "list.focusOutline", "focusBorder"}
     ]},
    {"side_bar", ".workbench-sideBar",
     [
       {"background-color", "sideBar.background", "editor.background"},
       {"color", "sideBar.foreground", "foreground"},
       {"border-color", "sideBar.border", "panel.border"}
     ]},
    {"panel", ".workbench-panel",
     [
       {"background-color", "panel.background", "editor.background"},
       {"color", "panel.foreground", "foreground"},
       {"border-color", "panel.border", "contrastBorder"}
     ]},
    {"quick_input", ".workbench-quickInput",
     [
       {"background-color", "quickInput.background", "editor.background"},
       {"color", "quickInput.foreground", "foreground"},
       {"border-color", "quickInput.border", "focusBorder"}
     ]},
    {"input", ".workbench-input",
     [
       {"background-color", "input.background", "editor.background"},
       {"color", "input.foreground", "foreground"},
       {"border-color", "input.border", "focusBorder"}
     ]},
    {"button", ".workbench-button",
     [
       {"background-color", "button.background", "focusBorder"},
       {"color", "button.foreground", "editor.background"},
       {"border-color", "button.border", "contrastBorder"}
     ]}
  ]

  @doc """
  Loads VS Code theme JSON from `path`, verifies WCAG contrast, and returns the
  generated stylesheet TEXT. The caller writes it to a file and declares that
  file in `stylesheets`.
  """
  @spec stylesheet_from_file!(Path.t(), keyword()) :: String.t()
  def stylesheet_from_file!(path, opts \\ []) when is_binary(path) and is_list(opts) do
    json = load_file!(path)
    verify_contrast!(json, opts)
    stylesheet!(json, opts)
  end

  @spec load_file!(Path.t()) :: map()
  def load_file!(path) when is_binary(path) do
    path
    |> Path.expand()
    |> do_load_file!(MapSet.new())
  end

  @spec stylesheet!(map(), keyword()) :: String.t()
  def stylesheet!(%{} = json, opts \\ []) when is_list(opts) do
    selector = Keyword.get(opts, :selector, ":root")
    colors = Map.get(json, "colors", %{}) || %{}

    [
      "/* Generated from VS Code theme #{Map.get(json, "name", "unknown")}. */",
      "#{selector} {",
      color_variables(colors),
      generic_variables(colors),
      "}",
      workbench_part_rules(),
      token_color_rules(Map.get(json, "tokenColors", []))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @spec verify_contrast!(map(), keyword()) :: :ok
  def verify_contrast!(%{} = json, opts \\ []) when is_list(opts) do
    case contrast_errors(json, opts) do
      [] ->
        :ok

      errors ->
        raise ArgumentError,
              "VS Code theme #{inspect(Map.get(json, "name"))} fails contrast: " <>
                Enum.join(errors, "; ")
    end
  end

  @spec contrast_errors(map(), keyword()) :: [String.t()]
  def contrast_errors(%{} = json, opts \\ []) when is_list(opts) do
    threshold = Keyword.get(opts, :contrast_threshold, @contrast_threshold)
    colors = Map.get(json, "colors", %{}) || %{}

    Enum.flat_map(@contrast_pairs, fn {foreground, background, label} ->
      with fg when is_binary(fg) <- Map.get(colors, foreground),
           bg when is_binary(bg) <- Map.get(colors, background),
           {:ok, fg_rgb} <- parse_css_color(fg),
           {:ok, bg_rgb} <- parse_css_color(bg),
           {:ok, ratio} <- contrast_ratio(fg_rgb, bg_rgb),
           true <- ratio < threshold do
        [
          "#{label} #{foreground}/#{background} ratio #{Float.round(ratio, 2)} below #{threshold}"
        ]
      else
        _other -> []
      end
    end)
  end

  defp do_load_file!(path, seen) do
    if MapSet.member?(seen, path) do
      raise ArgumentError, "recursive VS Code theme include: #{path}"
    end

    json =
      path
      |> File.read!()
      |> Jason.decode!()

    case Map.get(json, "include") do
      include when is_binary(include) ->
        path
        |> Path.dirname()
        |> Path.join(include)
        |> Path.expand()
        |> do_load_file!(MapSet.put(seen, path))
        |> merge_theme(json)

      _other ->
        json
    end
  end

  defp merge_theme(parent, child) do
    parent
    |> Map.merge(child)
    |> Map.put("colors", Map.merge(Map.get(parent, "colors", %{}), Map.get(child, "colors", %{})))
    |> Map.put("tokenColors", List.wrap(parent["tokenColors"]) ++ List.wrap(child["tokenColors"]))
    |> Map.put(
      "semanticTokenColors",
      Map.merge(
        Map.get(parent, "semanticTokenColors", %{}),
        Map.get(child, "semanticTokenColors", %{})
      )
    )
  end

  defp color_variables(colors) when is_map(colors) do
    colors
    |> Enum.filter(fn {_key, value} -> is_binary(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("\n", fn {key, value} ->
      "  #{vscode_var(key)}: #{value};"
    end)
  end

  defp generic_variables(colors) do
    @generic_tokens
    |> Enum.filter(fn {_generic, vscode_key} -> Map.has_key?(colors, vscode_key) end)
    |> Enum.map_join("\n", fn {generic, vscode_key} ->
      "  --#{generic}: var(#{vscode_var(vscode_key)});"
    end)
  end

  defp workbench_part_rules do
    Enum.map_join(@workbench_parts, "\n", fn {part, class, declarations} ->
      selectors = ~s([part="#{part}"], #{class})

      body =
        declarations
        |> Enum.map_join("\n", fn {property, key, fallback_key} ->
          "  #{property}: #{var_with_fallback(key, fallback_key)};"
        end)

      "#{selectors} {\n#{body}\n}"
    end)
  end

  defp token_color_rules(token_colors) when is_list(token_colors) do
    token_colors
    |> Enum.flat_map(&token_color_rule/1)
    |> Enum.join("\n")
  end

  defp token_color_rules(_token_colors), do: ""

  defp token_color_rule(%{"settings" => settings} = token) when is_map(settings) do
    scopes = token |> Map.get("scope", []) |> List.wrap() |> Enum.filter(&is_binary/1)
    declarations = token_settings_declarations(settings)

    if scopes == [] or declarations == [] do
      []
    else
      selector =
        scopes
        |> Enum.flat_map(&textmate_scope_selectors/1)
        |> Enum.join(", ")

      ["#{selector} { #{Enum.join(declarations, " ")} }"]
    end
  end

  defp token_color_rule(_token), do: []

  defp token_settings_declarations(settings) do
    []
    |> maybe_declaration("color", Map.get(settings, "foreground"))
    |> maybe_declaration("background-color", Map.get(settings, "background"))
    |> font_style_declarations(Map.get(settings, "fontStyle"))
  end

  defp maybe_declaration(acc, _property, nil), do: acc

  defp maybe_declaration(acc, property, value) when is_binary(value),
    do: acc ++ ["#{property}: #{value};"]

  defp font_style_declarations(acc, style) when is_binary(style) do
    style
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce(acc, fn
      "italic", next -> next ++ ["font-style: italic;"]
      "bold", next -> next ++ ["font-weight: 700;"]
      "underline", next -> next ++ ["text-decoration: underline;"]
      _other, next -> next
    end)
  end

  defp font_style_declarations(acc, _style), do: acc

  defp textmate_scope_selectors(scope) do
    escaped = String.replace(scope, "\"", "\\\"")
    class = scope |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")

    [
      ~s([part="code_block"] [data-tm-scope~="#{escaped}"]),
      ~s([part="code"] [data-tm-scope~="#{escaped}"]),
      ".tm-#{class}"
    ]
  end

  defp var_with_fallback(key, fallback_key) do
    "var(#{vscode_var(key)}, var(#{vscode_var(fallback_key)}, transparent))"
  end

  defp vscode_var(key) when is_binary(key), do: "--vscode-" <> String.replace(key, ".", "-")

  defp parse_css_color("#" <> hex) when byte_size(hex) in [3, 4] do
    hex
    |> String.graphemes()
    |> Enum.map(&(&1 <> &1))
    |> Enum.join()
    |> parse_hex_color()
  end

  defp parse_css_color("#" <> hex), do: parse_hex_color(hex)
  defp parse_css_color(_color), do: :error

  defp parse_hex_color(hex) when byte_size(hex) in [6, 8] do
    with {value, ""} <- Integer.parse(hex, 16) do
      case byte_size(hex) do
        6 ->
          {:ok, {band(value >>> 16, 0xFF), band(value >>> 8, 0xFF), band(value, 0xFF), 1.0}}

        8 ->
          alpha = band(value, 0xFF) / 255

          {:ok,
           {band(value >>> 24, 0xFF), band(value >>> 16, 0xFF), band(value >>> 8, 0xFF), alpha}}
      end
    else
      _other -> :error
    end
  end

  defp parse_hex_color(_hex), do: :error

  defp contrast_ratio(_fg, {_r, _g, _b, bg_alpha}) when bg_alpha < 1.0, do: :skip

  defp contrast_ratio({fr, fg, fb, fa}, {br, bg, bb, _ba}) do
    {fr, fg, fb} = blend({fr, fg, fb, fa}, {br, bg, bb})
    lighter = max(relative_luminance({fr, fg, fb}), relative_luminance({br, bg, bb}))
    darker = min(relative_luminance({fr, fg, fb}), relative_luminance({br, bg, bb}))
    {:ok, (lighter + 0.05) / (darker + 0.05)}
  end

  defp blend({r, g, b, 1.0}, _background), do: {r, g, b}

  defp blend({r, g, b, alpha}, {br, bg, bb}) do
    {
      r * alpha + br * (1 - alpha),
      g * alpha + bg * (1 - alpha),
      b * alpha + bb * (1 - alpha)
    }
  end

  defp relative_luminance({r, g, b}) do
    [r, g, b]
    |> Enum.map(&linear_channel/1)
    |> then(fn [lr, lg, lb] -> 0.2126 * lr + 0.7152 * lg + 0.0722 * lb end)
  end

  defp linear_channel(value) do
    value = value / 255

    if value <= 0.03928 do
      value / 12.92
    else
      :math.pow((value + 0.055) / 1.055, 2.4)
    end
  end
end
