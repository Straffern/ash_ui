defmodule AshUi.RenderTarget.HtmlTest do
  use ExUnit.Case, async: true
  alias AshUi.EventBinding
  alias AshUi.RenderTarget.Html
  alias AshUi.RenderTree

  test "lowers render-tree event metadata into the HTML target contract" do
    binding =
      EventBinding.new(:click, :save, args_exprs: %{id: "42"})

    attrs =
      %RenderTree.Element{
        tag: :button,
        attrs: %{"type" => "button"},
        event_bindings: [binding],
        children: []
      }
      |> Html.attrs()

    assert attrs["type"] == "button"
    assert attrs["data-ash-ui-on-click"] == "ash_ui:dispatch:i0.click"
    assert attrs["data-ash-ui-binding"] == "i0.click"
    refute Map.has_key?(attrs, "data-ash-ui-value-id")
  end

  test "event args stay server-side and do not emit DOM value attrs" do
    attrs =
      %RenderTree.Element{
        tag: :button,
        attrs: %{"type" => "button"},
        event_bindings: [
          EventBinding.new(:contextmenu, :open_context_menu,
            args_exprs: %{ref_uri: "vfs://root/file.txt"}
          ),
          EventBinding.new(:click, :open_entry,
            args_exprs: %{ref_uri: "vfs://root/file.txt", mime_type: "text/plain"}
          )
        ],
        children: []
      }
      |> Html.attrs()

    assert attrs["data-ash-ui-on-contextmenu"] ==
             "ash_ui:dispatch:i0.contextmenu"

    assert attrs["data-ash-ui-on-click"] == "ash_ui:dispatch:i0.click"
    assert attrs["data-ash-ui-binding"] == "i0.click"
    refute Enum.any?(Map.keys(attrs), &String.starts_with?(&1, "data-ash-ui-value-"))
  end

  test "value-provider input events do not serialize stale static value args" do
    attrs =
      %RenderTree.Element{
        tag: :input,
        attrs: %{"name" => "query"},
        event_bindings: [
          EventBinding.new(:input, :set_query,
            args_exprs: %{value: nil, scope: "main"},
            meta: %{provides_value?: true}
          )
        ],
        children: []
      }
      |> Html.attrs()

    assert attrs["data-ash-ui-on-input"] == "ash_ui:dispatch:i0.input"
    assert attrs["data-ash-ui-binding"] == "i0.input"
    refute Map.has_key?(attrs, "data-ash-ui-value-value")
    refute Map.has_key?(attrs, "data-ash-ui-value-scope")
  end

  test "input events retain the neutral input binding vocabulary" do
    tree = %RenderTree.Element{
      tag: :input,
      attrs: %{"name" => "query"},
      event_bindings: [EventBinding.new(:input, :set_query)],
      children: []
    }

    {:safe, iodata} = Html.render_static(tree)
    html = IO.iodata_to_binary(iodata)

    assert html =~ ~s(data-ash-ui-on-input="ash_ui:dispatch:i0.input")
    assert html =~ ~s(data-ash-ui-binding="i0.input")
  end

  test "DOM payload event args do not serialize nil static values over browser metadata" do
    attrs =
      %RenderTree.Element{
        tag: :div,
        attrs: %{"tabindex" => "0"},
        event_bindings: [EventBinding.new(:keydown, :tree_typeahead, args_exprs: %{key: nil})],
        children: []
      }
      |> Html.attrs()

    assert attrs["data-ash-ui-on-keydown"] == "ash_ui:dispatch:i0.keydown"
    assert attrs["data-ash-ui-binding"] == "i0.keydown"
    refute Map.has_key?(attrs, "data-ash-ui-value-key")
  end

  test "single-key filters retain the neutral key vocabulary" do
    tree = %RenderTree.Element{
      tag: :button,
      attrs: %{"type" => "button"},
      event_bindings: [
        EventBinding.new(:keydown, :save, meta: %{key_filter: %{key: "Enter", modifiers: []}})
      ],
      children: [%RenderTree.Text{content: "Save"}]
    }

    {:safe, iodata} = Html.render_static(tree)
    html = IO.iodata_to_binary(iodata)
    assert html =~ ~s"data-ash-ui-on-keydown=\"ash_ui:dispatch:i0.keydown\""
    assert html =~ ~s"data-ash-ui-key=\"Enter\""
    assert html =~ ~s"data-ash-ui-binding=\"i0.keydown\""
  end

  test "binding options and window-scoped events retain neutral attrs" do
    tree = %RenderTree.Element{
      tag: :div,
      attrs: %{"tabindex" => "0", "data-ash-ui-throttle" => 125},
      event_bindings: [
        EventBinding.new(:window_keydown, :close,
          meta: %{prevent_default: true, stop_propagation: true}
        )
      ],
      children: [%RenderTree.Text{content: "Close"}]
    }

    {:safe, iodata} = Html.render_static(tree)
    html = IO.iodata_to_binary(iodata)

    assert html =~
             ~s"data-ash-ui-on-window-keydown=\"ash_ui:dispatch:i0.window-keydown\""

    assert html =~ ~s"data-ash-ui-throttle=\"125\""
    assert html =~ ~s"data-ash-ui-binding=\"i0.window-keydown\""
    assert html =~ ~s"data-ash-ui-prevent-default=\"window-keydown\""
    assert html =~ ~s"data-ash-ui-stop-propagation=\"window-keydown\""
  end

  test "lowers navigation and route patch metadata into neutral attrs" do
    attrs =
      %RenderTree.Element{
        tag: :a,
        attrs: %{"href" => "/staff/invoices", "class" => "abp-action"},
        meta: %{
          route_patch_form: %{screen: :invoices},
          navigation: %{kind: :patch, state: :replace}
        },
        children: []
      }
      |> Html.attrs()

    assert attrs["data-ash-ui-link"] == "patch"
    assert attrs["data-ash-ui-link-state"] == "replace"
    assert attrs["data-ash-ui-change"] == "ash_ui:route-params-patch"
    assert attrs["data-ash-ui-submit"] == "ash_ui:route-params-patch"
    assert attrs["data-ash-ui-route-patch-form"] == "invoices"
  end

  test "serializes context menu event atoms with DOM action names" do
    attrs =
      %RenderTree.Element{
        tag: :button,
        attrs: %{"data-ash-ui-on-contextmenu" => :open_context_menu},
        children: []
      }
      |> Html.attrs()

    assert attrs["data-ash-ui-on-contextmenu"] == "open-context-menu"
  end

  test "serializes ARIA booleans as strings without changing HTML boolean semantics" do
    element = %RenderTree.Element{
      tag: :button,
      attrs: %{
        "aria-selected" => false,
        :aria_expanded => true,
        "disabled" => false,
        "hidden" => true
      },
      children: []
    }

    attrs = Html.attrs(element)
    assert attrs["aria-expanded"] == "true"
    assert attrs["aria-selected"] == "false"
    assert attrs["hidden"] == true
    refute Map.has_key?(attrs, "disabled")

    assert {:safe, iodata} = Html.render_static(element)
    html = IO.iodata_to_binary(iodata)

    assert html =~ ~s(aria-expanded="true")
    assert html =~ ~s(aria-selected="false")
    assert html =~ " hidden"
    refute html =~ " disabled"
  end

  test "escapes large text nodes as exact iodata" do
    prefix = String.duplicate("A long, clean document line.\n", 64)

    assert prefix <> "&lt;&amp;&gt;&quot;&#39;" ==
             [prefix, "<&>\"'"]
             |> Html.html_escape()
             |> IO.iodata_to_binary()
  end

  test "text nodes keep quotes literal while escaping HTML-significant bytes" do
    tree = %RenderTree.Text{content: ~s(<tag a="quoted">Tom's & Jerry</tag>)}
    {:safe, iodata} = Html.render_static(tree)

    assert ~s(&lt;tag a="quoted">Tom's &amp; Jerry&lt;/tag>) ==
             IO.iodata_to_binary(iodata)
  end
end
