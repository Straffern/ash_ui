defmodule AshUi.Datastar.RenderTargetTest do
  use ExUnit.Case, async: true

  alias AshUi.Datastar.RenderTarget
  alias AshUi.EventBinding
  alias AshUi.RenderTarget.Html
  alias AshUi.RenderTree.Element

  test "maps event attributes and passes unknown target attrs" do
    assert RenderTarget.attr_name("data-ash-ui-on-click") == "data-on:click"
    assert RenderTarget.attr_name("data-ash-ui-submit") == "data-on:submit"

    assert RenderTarget.attr_name("data-ash-ui-client-hook") ==
             "data-ash-ui-client-hook"

    assert RenderTarget.attr_name("data-ash-ui-dom-update") == "data-ignore-morph"
    assert RenderTarget.attr_name("aria-label") == "aria-label"
  end

  test "dispatch event value URL-encodes the one binding-key language" do
    assert RenderTarget.dispatch_event_value("row/a click") ==
             "@post('/_ash_ui/dispatch/row%2Fa%20click', " <>
               "{headers: {'ash-ui-client-id': globalThis.__ashUiDatastarClientId}})"
  end

  test "skeleton attributes retain identity presence without evaluating dynamic values" do
    attrs = %{
      "id" => {:dynamic, :id},
      "href" => {:dynamic, :href},
      "data-ash-ui-binding-click" => "binding"
    }

    assert RenderTarget.finalize_skeleton_attrs(attrs) == %{"id" => ""}
  end

  test "declared event fields become the native Datastar request payload" do
    element = %Element{
      tag: :form,
      attrs: %{},
      children: [],
      event_bindings: [
        EventBinding.new(:change, :change_sort,
          args_exprs: %{sort_by: {:event, :value}},
          meta: %{provides_form?: true}
        )
      ],
      meta: %{}
    }

    {:safe, iodata} = Html.render_static(element, target: RenderTarget)
    html = IO.iodata_to_binary(iodata)

    assert html =~ "data-on:change=\"@post("
    assert html =~ "/_ash_ui/dispatch/"
    assert html =~ "&quot;value&quot;: evt.target.value"
    refute html =~ "data-bind="
    refute html =~ "data-ash-ui-binding"
  end

  test "reorder always transports the semantic order payload" do
    element = %Element{
      tag: :tbody,
      attrs: %{},
      children: [],
      event_bindings: [EventBinding.new(:reorder, :reorder_tracks)],
      meta: %{}
    }

    {:safe, iodata} = Html.render_static(element, target: RenderTarget)
    html = IO.iodata_to_binary(iodata)

    assert html =~ "data-on:reorder=\"@post("
    assert html =~ "&quot;order&quot;: evt.detail &amp;&amp; evt.detail.order"
  end

  test "stable ids use neutral addresses and keyed chains without replacing authored ids" do
    then_arm = element("v/3/t/0", [])
    else_arm = element("v/3/f/0", [])
    first_entry = element("v/4/*/0", ["row-1"])
    second_entry = element("v/4/*/0", ["row-2"])

    assert RenderTarget.finalize_tree(then_arm).attrs["id"] ==
             RenderTarget.finalize_tree(else_arm).attrs["id"]

    refute RenderTarget.finalize_tree(first_entry).attrs["id"] ==
             RenderTarget.finalize_tree(second_entry).attrs["id"]

    authored = %{element("v/0", []) | attrs: %{"id" => "mine"}}
    assert RenderTarget.finalize_tree(authored).attrs["id"] == "mine"
  end

  defp element(address, chain) do
    %Element{
      tag: :div,
      attrs: %{},
      children: [],
      meta: %{__bp_addr__: address, __bp_runtime_chain__: chain}
    }
  end
end
