defmodule AshUi.Phoenix.RootLayout do
  @moduledoc """
  Document assembly for routed AshUi resources (DESIGN.md §9).

  The layout is a framework function of declared data — there are no
  `root_layout_*` env/assign channels and no fallback hrefs:

  - `<base href>` derived from the mount scope (`conn.script_name`), so
    relative stylesheet hrefs resolve correctly at any route depth.
  - One `<link rel="stylesheet">` per EFFECTIVE stylesheet of the routed
    resource (`AshUi.Info.stylesheets/1`), linked in declared order.
    Each declared entry is served as-declared, resolved against the base.
  - The framework runtime scripts (`blueprint_runtime_script_paths/0`),
    unconditional.
  - Runtime-state stamping (see below).

  ## Runtime state contract

  Runtime state is host-stamped, never compiled: a map with the optional keys
  `:scheme`, `:fonts`, and `:zoom`, provided under the SINGLE key
  `:ash_ui_runtime_state` — as a layout assign, or in the Plug session
  under `"ash_ui_runtime_state"` (assign wins):

      %{scheme: "dark", fonts: %{ui: "Inter", mono: "Iosevka"}, zoom: 1.25}

  Stamping (each key only when present; absent runtime state stamps nothing):

  - `scheme` → `data-theme="<scheme>"` on `<html>`. Palette blocks live in
    token stylesheets keyed on `:root[data-theme=…]`.
  - `fonts` → one `--font-<name>: <value>` custom property per entry, inline
    on `<html>`.
  - `zoom` → the `<html>` root `font-size` (`16px * zoom`). Generated layout
    sizing is rem-based, so this is the single document scale knob.

  A theme or font change is an attribute/token flip — never a re-link, never
  a recompile.
  """

  alias AshUi.Phoenix.RouteMetadata

  def render(assigns) when is_map(assigns) do
    otp_app = AshUi.Phoenix.otp_app(assigns)
    conn = assigns[:conn]
    runtime_state = runtime_state(assigns, conn)

    context = %{
      document_title:
        document_title(
          assigns[:page_title],
          assigns[:page_title_suffix] || Application.get_env(otp_app, :root_layout_title_suffix),
          assigns[:root_layout_default_title] ||
            Application.get_env(otp_app, :root_layout_default_title, "AshUi")
        ),
      csrf_token: Plug.CSRFProtection.get_csrf_token(),
      base_href: base_href(conn),
      stylesheets: effective_stylesheets(conn),
      script_paths: blueprint_runtime_script_paths(),
      runtime_state: runtime_state
    }

    document(assigns, context)
  end

  @doc """
  The framework runtime script paths, linked unconditionally in every
  AshUi document.
  """
  def blueprint_runtime_script_paths do
    [
      {"/assets/phoenix.min.js", "text/javascript"},
      {"/assets/phoenix_live_view.min.js", "text/javascript"},
      {"/assets/ash_ui.min.js", "text/javascript"}
    ]
  end

  defp document(assigns, context) do
    {:safe, inner_content} = {:safe, Phoenix.HTML.Safe.to_iodata(assigns[:inner_content])}

    {:safe,
     [
       "<!DOCTYPE html><html",
       html_runtime_state_attrs(context.runtime_state),
       "><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
       "<meta name=\"csrf-token\" content=\"",
       safe_iodata(Phoenix.HTML.html_escape(context.csrf_token)),
       "\"><base href=\"",
       safe_iodata(Phoenix.HTML.html_escape(context.base_href)),
       "\"><title>",
       safe_iodata(Phoenix.HTML.html_escape(context.document_title)),
       "</title>",
       stylesheet_tags(context.stylesheets),
       script_tags(context.script_paths),
       "</head><body>",
       inner_content,
       "</body></html>"
     ]}
  end

  # The routed resource is threaded by the framework mount plumbing: the
  # router stamps route metadata into the route's private map, and the
  # resource's EFFECTIVE stylesheets (declared or substrate-supplied,
  # compile-verified) are the document's link set. No metadata means a
  # non-AshUi route rendering through this layout: it links nothing —
  # there are no default stylesheets.
  defp effective_stylesheets(%Plug.Conn{} = conn) do
    case RouteMetadata.from_private(conn.private) do
      %RouteMetadata{resource: resource} when is_atom(resource) ->
        AshUi.Info.stylesheets(resource)

      _none ->
        []
    end
  end

  defp effective_stylesheets(_conn), do: []

  # <base href> from the mount scope: relative stylesheet hrefs resolve
  # against the scope the routes are mounted under, at any route depth.
  defp base_href(%Plug.Conn{script_name: []}), do: "/"

  defp base_href(%Plug.Conn{script_name: segments}) when is_list(segments),
    do: "/" <> Enum.join(segments, "/") <> "/"

  defp base_href(_conn), do: "/"

  defp runtime_state(assigns, conn) do
    case fetch_assign(assigns, :ash_ui_runtime_state) do
      {:ok, %{} = state} -> state
      _missing -> session_runtime_state(conn)
    end
  end

  defp session_runtime_state(%Plug.Conn{} = conn) do
    case Plug.Conn.get_session(conn, "ash_ui_runtime_state") do
      %{} = state -> state
      _missing -> nil
    end
  rescue
    # Session not fetched on this pipeline: no runtime state to stamp.
    ArgumentError -> nil
  end

  defp session_runtime_state(_conn), do: nil

  defp html_runtime_state_attrs(nil), do: []

  defp html_runtime_state_attrs(%{} = state) do
    [
      data_theme_attr(state_value(state, :scheme)),
      html_style_attr(font_declarations(state_value(state, :fonts)), zoom_declaration(state))
    ]
  end

  defp data_theme_attr(nil), do: []

  defp data_theme_attr(scheme) do
    [" data-theme=\"", safe_iodata(Phoenix.HTML.html_escape(to_string(scheme))), "\""]
  end

  defp html_style_attr([], nil), do: []

  defp html_style_attr(font_declarations, zoom_declaration) do
    declarations = font_declarations ++ List.wrap(zoom_declaration)

    [
      " style=\"",
      safe_iodata(Phoenix.HTML.html_escape(Enum.join(declarations, "; "))),
      "\""
    ]
  end

  defp font_declarations(%{} = fonts) do
    fonts
    |> Enum.sort_by(fn {name, _value} -> to_string(name) end)
    |> Enum.map(fn {name, value} -> "--font-#{name}: #{value}" end)
  end

  defp font_declarations(_fonts), do: []

  defp zoom_declaration(state) do
    case normalize_zoom(state_value(state, :zoom)) do
      nil ->
        nil

      value ->
        {zoom, ""} = Float.parse(value)

        pixels =
          (zoom * 16)
          |> :erlang.float_to_binary(decimals: 4)
          |> String.trim_trailing("0")
          |> String.trim_trailing(".")

        "font-size: #{pixels}px"
    end
  end

  defp normalize_zoom(zoom) when is_integer(zoom) and zoom > 0,
    do: Integer.to_string(zoom)

  defp normalize_zoom(zoom) when is_float(zoom) and zoom > 0 do
    zoom
    |> :erlang.float_to_binary(decimals: 4)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp normalize_zoom(zoom) when is_binary(zoom) do
    case Float.parse(zoom) do
      {value, ""} when value > 0 -> normalize_zoom(value)
      _other -> nil
    end
  end

  defp normalize_zoom(_zoom), do: nil

  defp state_value(state, key) when is_atom(key) do
    Map.get(state, key, Map.get(state, Atom.to_string(key)))
  end

  defp stylesheet_tags(paths) do
    Enum.map(paths, fn path ->
      [
        "<link phx-track-static rel=\"stylesheet\" href=\"",
        safe_iodata(Phoenix.HTML.html_escape(path)),
        "\">"
      ]
    end)
  end

  defp script_tags(paths) do
    Enum.map(paths, fn {path, type} ->
      [
        "<script defer phx-track-static type=\"",
        safe_iodata(Phoenix.HTML.html_escape(type)),
        "\" src=\"",
        safe_iodata(Phoenix.HTML.html_escape(path)),
        "\"></script>"
      ]
    end)
  end

  defp document_title(title, suffix, default_title) do
    to_string(title || default_title) <> to_string(suffix || "")
  end

  defp safe_iodata({:safe, iodata}), do: iodata

  defp fetch_assign(assigns, key) when is_map(assigns) and is_atom(key) do
    case Map.fetch(assigns, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(assigns, Atom.to_string(key))
    end
  end
end
