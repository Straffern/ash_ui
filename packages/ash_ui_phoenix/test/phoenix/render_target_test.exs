defmodule AshUi.Phoenix.RenderTargetTest do
  use ExUnit.Case, async: true

  alias AshUi.EventBinding
  alias AshUi.Phoenix.RenderTarget
  alias AshUi.RenderTarget.Html
  alias AshUi.RenderTree.{Element, Text}

  test "maps the neutral binding protocol directly to the live wire vocabulary" do
    tree = %Element{
      tag: :button,
      attrs: %{
        "data-ash-ui-client-hook" => "Demo",
        "data-ash-ui-dom-update" => "ignore"
      },
      event_bindings: [EventBinding.new(:click, :save)],
      children: [%Text{content: "Save"}]
    }

    tree = RenderTarget.finalize_tree(tree)
    {:safe, iodata} = Html.render_static(tree, target: RenderTarget)
    html = IO.iodata_to_binary(iodata)

    assert html =~ ~s(phx-click="ash_ui:dispatch:i0.click")
    refute html =~ "phx-value-binding"
    refute html =~ "data-ash-ui-binding"
    assert html =~ ~s(phx-hook="Demo")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~r/id="bp-[0-9a-f]{12}"/
  end

  test "address-format binding keys remain embedded in the native event" do
    tree = %Element{
      tag: :button,
      meta: %{__bp_binding_chain__: ["child-v-0", "v"]},
      event_bindings: [EventBinding.new(:click, :save)],
      children: []
    }

    {:safe, iodata} = Html.render_static(tree, target: RenderTarget)
    html = IO.iodata_to_binary(iodata)

    assert html =~ ~s(phx-click="ash_ui:dispatch:child-v-0.v.click")
    refute html =~ "phx-value-binding"
    refute html =~ "data-ash-ui-binding"
  end

  test "multi-event elements retain qualified component-event lookup keys" do
    tree = %Element{
      tag: :button,
      meta: %{__bp_binding_chain__: ["toolbar", "save"]},
      event_bindings: [
        EventBinding.new(:click, :save),
        EventBinding.new(:keydown, :save)
      ],
      children: []
    }

    attrs = Html.attrs(tree, target: RenderTarget)

    assert attrs["phx-click"] == "ash_ui:dispatch:toolbar.save.click"
    assert attrs["phx-keydown"] == "ash_ui:dispatch:toolbar.save.keydown"
    assert attrs["data-ash-ui-binding-click"] == "toolbar.save.click"
    assert attrs["data-ash-ui-binding-keydown"] == "toolbar.save.keydown"
    assert attrs["phx-value-binding"] in ["toolbar.save.click", "toolbar.save.keydown"]
  end

  test "maps declared Ash routes to LiveView patch and redirect links only" do
    attrs = fn href ->
      %Element{
        tag: :a,
        attrs: %{"href" => href},
        meta: %{
          screen_navigation?: true,
          screen_navigation_routes: ["/nav", "/destination/:id"],
          screen_navigation_patch_routes: ["/nav"]
        },
        children: []
      }
      |> Html.attrs(target: RenderTarget)
    end

    assert attrs.("/nav?tab=details")["data-phx-link"] == "patch"
    assert attrs.("/nav?tab=details")["data-phx-link-state"] == "push"
    assert attrs.("/destination/42")["data-phx-link"] == "redirect"
    assert attrs.("/destination/42")["data-phx-link-state"] == "push"
    refute Map.has_key?(attrs.("/sign-out"), "data-phx-link")
    refute Map.has_key?(attrs.("https://example.com"), "data-phx-link")
  end

  test "generated ids stay stable across unrelated siblings and disambiguate duplicates" do
    region = fn label ->
      %Element{
        tag: :div,
        attrs: %{"data-ash-ui-client-hook" => "Demo"},
        meta: %{node: :client_region},
        children: [%Text{content: label}]
      }
    end

    before = %Element{tag: :main, children: [%Element{tag: :p}, region.("Client")]}

    after_tree = %Element{
      tag: :main,
      children: [%Element{tag: :p}, %Element{tag: :p}, region.("Client")]
    }

    assert hook_ids(RenderTarget.finalize_tree(before)) ==
             hook_ids(RenderTarget.finalize_tree(after_tree))

    duplicates = %Element{tag: :main, children: [region.("First"), region.("Second")]}
    [first, second] = hook_ids(RenderTarget.finalize_tree(duplicates))
    assert first != second
  end

  test "the adapter does not rewrite serialized output after lowering" do
    source =
      Path.expand("../../lib/ash_ui/phoenix", __DIR__)
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    refute source =~ "phoenixize_html"
    refute source =~ "ensure_client_hook_ids"
    refute source =~ "normalize_phx_atom_attr_values"
    refute source =~ "Regex."
  end

  defp hook_ids(%Element{} = element) do
    own =
      if Map.has_key?(element.attrs, "data-ash-ui-client-hook") do
        [Map.fetch!(element.attrs, "id")]
      else
        []
      end

    own ++ Enum.flat_map(element.children, &hook_ids/1)
  end

  defp hook_ids(_node), do: []
end
