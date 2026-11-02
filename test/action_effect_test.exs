defmodule AshUi.ActionEffectTest.Page do
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
    attribute(:session_id, :uuid, allow_nil?: false, primary_key?: true, public?: false)
    attribute(:anchor, :string, public?: true)
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  actions do
    defaults([:read])

    create :mount do
      argument(:anchor, :string)
      change(set_attribute(:anchor, arg(:anchor)))

      change(
        scroll_into_view(
          part: :document_match,
          block: :center,
          when_arguments: [:anchor]
        )
      )
    end
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text(anchor)))
  end
end

defmodule AshUi.ActionEffectTest do
  use ExUnit.Case, async: false

  alias AshUi.ActionEffectTest.Page

  test "a successful action emits its declared DOM affordance exactly once" do
    effect_ref = make_ref()

    context = %{
      session_id: Ash.UUID.generate(),
      ash_ui_action_effect_pid: self(),
      ash_ui_action_effect_ref: effect_ref
    }

    assert {:ok, %Page{anchor: "quoted text"}} =
             Page
             |> Ash.Changeset.for_create(:mount, %{anchor: "quoted text"},
               context: context,
               domain: AshUi.AshDomainFallback
             )
             |> Ash.create(domain: AshUi.AshDomainFallback)

    assert_receive {:ash_ui_action_effect, ^effect_ref,
                    %AshUi.ActionEffect{
                      name: :scroll_into_view,
                      target: {:part, "document_match"},
                      options: %{options: %{block: :center, inline: :nearest, behavior: :auto}}
                    }}

    refute_receive {:ash_ui_action_effect, ^effect_ref, _effect}
  end

  test "an absent guarded argument emits no effect" do
    effect_ref = make_ref()

    context = %{
      session_id: Ash.UUID.generate(),
      ash_ui_action_effect_pid: self(),
      ash_ui_action_effect_ref: effect_ref
    }

    assert {:ok, %Page{anchor: nil}} =
             Page
             |> Ash.Changeset.for_create(:mount, %{},
               context: context,
               domain: AshUi.AshDomainFallback
             )
             |> Ash.create(domain: AshUi.AshDomainFallback)

    refute_receive {:ash_ui_action_effect, ^effect_ref, _effect}
  end

  test "the host payload is a closed semantic target, not a feature selector" do
    effect = %AshUi.ActionEffect{
      name: :scroll_into_view,
      target: {:part, "document_match"},
      options: %{options: %{block: :center}}
    }

    assert AshUi.ActionEffect.event_name(effect) == "ash_ui:scroll-into-view"

    assert AshUi.ActionEffect.payload(effect) == %{
             part: "document_match",
             options: %{block: :center}
           }

    assert {:error, message} =
             AshUi.Changes.EmitActionEffect.init(
               effect: :scroll_into_view,
               id: "target",
               selector: ".feature-owned-selector"
             )

    assert message =~ "undeclared action effect options"
  end
end
