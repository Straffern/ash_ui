defmodule AshUi.DefectClass.DC3NoHtmlRewritingTest do
  use ExUnit.Case, async: true
  alias AshUi.EventBinding
  alias AshUi.RenderTarget.Html
  alias AshUi.RenderTree

  test "static target emits neutral attrs directly" do
    tree = %RenderTree.Element{
      tag: :button,
      attrs: %{"type" => "button"},
      event_bindings: [EventBinding.new(:click, :save_draft)],
      children: [%RenderTree.Text{content: "Save"}]
    }

    {:safe, iodata} = Html.render_static(tree)
    html = IO.iodata_to_binary(iodata)
    assert html =~ ~s"data-ash-ui-on-click=\"ash_ui:dispatch:i0.click\""
    assert html =~ ~s"data-ash-ui-binding=\"i0.click\""
  end
end
