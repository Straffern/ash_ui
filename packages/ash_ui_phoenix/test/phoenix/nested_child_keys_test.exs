defmodule AshUi.Phoenix.NestedChildKeysTest do
  @moduledoc """
  ONE key language on the LIVE path: every binding key the differential
  renderer ships resolves against the page row — through an embedded
  shell, a store-backed session child, and a store child nested inside
  THAT (the app-shell/nav/bell shape). Chains accumulate; child scopes
  never sever them.
  """
  use ExUnit.Case, async: false

  alias AshUi.Patch.Bindings
  alias AshUi.Phoenix.LiveRender
  alias Phoenix.LiveView.Diff

  defmodule Bell do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:session_id, :uuid, allow_nil?: false, public?: false)
      attribute(:open?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, create: :*])

      create(:mount)

      update :toggle do
        require_atomic?(false)

        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :open?, not changeset.data.open?)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(box(:bell, [tabindex: 0, on_click: :toggle], [text("bell")]))
      )
    end
  end

  defmodule Nav do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:session_id, :uuid, allow_nil?: false, public?: false)
      attribute(:signed_in?, :boolean, allow_nil?: false, default: false, public?: true)
      attribute(:menu_open?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_one(:bell, Bell,
        source_attribute: :session_id,
        destination_attribute: :session_id,
        public?: true
      )
    end

    actions do
      defaults([:read, create: :*])

      create(:mount)

      update :toggle_menu do
        require_atomic?(false)

        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :menu_open?, not changeset.data.menu_open?)
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:nav_root, [], [
            if signed_in? do
              box(:signed_in_zone, [], [
                render(AshUi.Phoenix.NestedChildKeysTest.Bell, %{}),
                box(:avatar, [tabindex: 0, role: "button", on_click: :toggle_menu], [
                  text("avatar")
                ])
              ])
            else
              text("anon")
            end
          ])
        )
      )
    end
  end

  defmodule Shell do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:signed_in?, :boolean, allow_nil?: false, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:shell_root, [], [
            render(AshUi.Phoenix.NestedChildKeysTest.Nav, %{signed_in?: signed_in?}),
            box(:shell_body, [], [text("body")])
          ])
        )
      )
    end
  end

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :uuid, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:signed_in?, :boolean, allow_nil?: false, default: true, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_one(:nav, Nav,
        source_attribute: :session_id,
        destination_attribute: :session_id,
        public?: true
      )
    end

    actions do
      defaults([:read, create: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(render(AshUi.Phoenix.NestedChildKeysTest.Shell, %{signed_in?: signed_in?}))
      )
    end
  end

  test "every LIVE-rendered binding key resolves; dispatch reaches the deepest row" do
    page = Ash.Seed.seed!(Page, %{session_id: Ash.UUID.generate(), signed_in?: true})

    {full, _prints, _components} =
      Diff.render(
        %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}},
        LiveRender.build(page, :all, session_id: page.session_id),
        Diff.new_fingerprints(),
        Diff.new_components()
      )

    html =
      Phoenix.LiveViewTest.Diff.merge_diff(%{}, full)
      |> Map.delete(:streams)
      |> Diff.to_iodata()
      |> IO.iodata_to_binary()

    keys =
      ~r/phx-(?:click|keydown)="ash_ui:dispatch:([^"]+)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()

    assert length(keys) == 2, "expected bell + avatar keys: #{inspect(keys)}"

    resolved =
      for key <- keys do
        assert {:ok, binding, {:row, %row_resource{} = row}} =
                 Bindings.resolve(page, key, %{}, session_id: page.session_id),
               "live key #{inspect(key)} must resolve"

        {binding.ui_event, row_resource, row}
      end

    events = resolved |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert events == [:toggle, :toggle_menu]

    # dispatch through the ONE entry — lazy store rows persist at first
    # write (Dispatch.run's ensure_store_row), then the action flips them
    {_event, Bell, bell_row} = Enum.find(resolved, &match?({:toggle, Bell, _}, &1))

    assert {:ok, _updated} =
             AshUi.Patch.Dispatch.run(page, {:row, bell_row}, :toggle, %{}, [])

    assert [%{open?: true}] =
             Bell
             |> Ash.read!(authorize?: false, domain: AshUi.AshDomainFallback)
             |> Enum.filter(&(&1.session_id == page.session_id))
  end
end
