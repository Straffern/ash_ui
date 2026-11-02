defmodule AshUi.Phoenix.IslandContractTest do
  use ExUnit.Case, async: false

  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Runtime, as: PatchRuntime
  alias AshUi.Phoenix, as: Bridge
  alias AshUi.Phoenix.LiveRender
  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveViewTest.Diff, as: Client

  defmodule Page do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:count, :integer, allow_nil?: false, default: 1, public?: true)
      attribute(:base_rev, :integer, allow_nil?: false, default: 0, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :engine_state do
        require_atomic?(false)
        argument(:count, :integer, allow_nil?: false)
        argument(:base_rev, :integer, allow_nil?: false)
        change(set_attribute(:count, arg(:count)))
        change(set_attribute(:base_rev, arg(:base_rev)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          island(
            "counter",
            props: %{count: count, rev: base_rev},
            on: [changed: :engine_state]
          )
        )
      )
    end
  end

  defmodule ShellPage do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:rev, :integer, allow_nil?: false, default: 0, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:shell, [part: :workbench_shell], [
            text("Connected"),
            island("workbench-gl", props: %{rev: rev})
          ])
        )
      )
    end
  end

  defp seed do
    Ash.Seed.seed!(Page, %{session_id: Ash.UUID.generate()})
  end

  defp lv_render(rendered, prints) do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {diff, prints, _components} =
      Diff.render(socket, rendered, prints || Diff.new_fingerprints(), Diff.new_components())

    {diff, prints}
  end

  defp paint(client_state) do
    client_state
    |> Map.delete(:streams)
    |> Diff.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "island mount renders an ignored stable root and prop changes ship only the payload" do
    page = seed()
    table = Compiler.table(Page, :view, target: AshUi.Phoenix.RenderTarget)

    {full, prints} = lv_render(LiveRender.build(page, :all, table: table), nil)
    client = Client.merge_diff(%{}, full)
    html = paint(client)

    assert html =~ ~s(phx-hook="AshUiIsland")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(id="ash-ui-island-sY291bnRlcg")
    assert html =~ ~s(data-ash-ui-island-props="{&quot;count&quot;:1,&quot;rev&quot;:0}")

    updated = %{page | count: 7}
    changed = PatchRuntime.changed_addresses(table, page, updated)
    {diff, _prints} = lv_render(LiveRender.build(updated, changed, table: table), prints)

    dynamic_strings =
      diff
      |> flatten_diff()
      |> Enum.filter(&is_binary/1)

    assert dynamic_strings == [
             ~s( data-ash-ui-island-props="{&quot;count&quot;:7,&quot;rev&quot;:0}")
           ]

    patched_html = client |> Client.merge_diff(diff) |> paint()
    assert patched_html =~ ~s(data-ash-ui-island-props="{&quot;count&quot;:7)
    assert patched_html =~ ~s(phx-update="ignore")
    assert patched_html =~ ~s(id="ash-ui-island-sY291bnRlcg")
  end

  test "page-error patch cycles place the alert after a trailing island without stray text" do
    page = Ash.Seed.seed!(ShellPage, %{session_id: Ash.UUID.generate()})

    assigns = %{
      ash_ui_record: page,
      ash_ui_changed: :all,
      ash_ui_view: :view,
      ash_ui_actor: nil,
      ash_ui_tenant: nil,
      ash_ui_context: %{},
      ash_ui_session_id: page.session_id,
      ash_ui_params: %{},
      ash_ui_errors: []
    }

    {full, prints} = lv_render(Bridge.render_shell(assigns), nil)
    client = Client.merge_diff(%{}, full)

    errors = [%Ash.Error.Changes.InvalidChanges{message: "stale shell state"}]

    {error_diff, prints} =
      lv_render(
        Bridge.render_shell(%{
          assigns
          | ash_ui_changed: MapSet.new(),
            ash_ui_errors: errors
        }),
        prints
      )

    client = Client.merge_diff(client, error_diff)
    html = paint(client)
    {document, _tree} = Phoenix.LiveViewTest.DOM.parse_fragment(html)
    shell = Phoenix.LiveViewTest.DOM.all(document, ~s([part="workbench_shell"]))

    assert html =~
             ~s(phx-update="ignore"></div><div part="wb_error" data-ash-ui-error="page" role="alert">stale shell state</div></section>)

    assert Phoenix.LiveViewTest.DOM.all(document, ~s([part="wb_error"][role="alert"])) != []

    refute Phoenix.LiveViewTest.DOM.to_text(shell) =~ ">"

    {clear_diff, _prints} =
      lv_render(
        Bridge.render_shell(%{
          assigns
          | ash_ui_changed: MapSet.new(),
            ash_ui_errors: []
        }),
        prints
      )

    cleared_html = client |> Client.merge_diff(clear_diff) |> paint()
    refute cleared_html =~ ~s(data-ash-ui-error="page")
  end

  test "emit payload resolves the island binding and casts typed action arguments" do
    page = seed()
    table = Compiler.table(Page, :view, target: AshUi.Phoenix.RenderTarget)
    [{address, entry}] = Map.to_list(table.event_elements)
    [binding] = entry.node.events

    binding_key =
      Compiler.addr_component(address) <>
        "." <> AshUi.EventBinding.event_key_component(binding.dom_event)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        ash_ui_record: page,
        ash_ui_resource: Page,
        ash_ui_view: :view,
        ash_ui_tables: %{{Page, :view, AshUi.Phoenix.RenderTarget} => table},
        ash_ui_params: %{},
        ash_ui_session_id: page.session_id,
        ash_ui_actor: nil,
        ash_ui_location: "/"
      }
    }

    {:noreply, updated} =
      Bridge.runtime_handle_event(
        "ash_ui:dispatch",
        %{
          "binding" => binding_key,
          "count" => "12",
          "base_rev" => "41",
          "ignored_transport_field" => "not an action argument"
        },
        socket
      )

    assert updated.assigns.ash_ui_record.count == 12
    assert updated.assigns.ash_ui_record.base_rev == 41
    assert updated.assigns[:ash_ui_errors] in [nil, []]
  end

  defp flatten_diff(%{} = diff) do
    Enum.flat_map(diff, fn
      {key, %{} = nested} when is_integer(key) -> flatten_diff(nested)
      {key, value} when is_integer(key) -> [value]
      _other -> []
    end)
  end

  defp flatten_diff(_other), do: []
end
