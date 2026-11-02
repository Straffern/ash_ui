defmodule AshUi.DefectClass.DC31EmbeddedParentUpdateTest do
  @moduledoc """
  DC-31: dispatching an action on an embedded instance IS a parent update
  (nested_ui_model.md). The parent row is the only durable state; the
  embedded record is addressed by its primary key inside the parent
  attribute, the embedded action runs against it, and the result persists
  as ONE parent update (one parent notification).

  ENGINE GAP (second-model deletion): the deleted Runtime facade owned the
  embedded-dispatch executor (path -> embedded record -> run embedded
  action -> write back into the parent attribute -> single parent update).
  The surviving library resolves bindings into embedded child records
  (`AshUi.Patch.Bindings` walks child records), but nothing executes
  an embedded target's action as a parent update. The bridge (or a core
  seam next to Bindings) must own: locate item by pk in the parent
  attribute (insert-with-defaults when absent), run the embedded action's
  changes against that instance, `Ash.update!` the parent with the new
  attribute value, exactly one parent notification.
  """
  use ExUnit.Case, async: false

  defmodule ParentNotifier do
    use Ash.Notifier

    @impl true
    def notify(%Ash.Notifier.Notification{actor: actor} = notification) when is_pid(actor) do
      send(actor, {:parent_notification, notification})
      :ok
    end

    def notify(_notification), do: :ok
  end

  defmodule Fold do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:name, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:collapsed?, :boolean, allow_nil?: false, default: false, public?: true)
      attribute(:created?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    actions do
      defaults([:read, :destroy, update: :*])

      create :create do
        primary?(true)
        accept([:name])
        change(set_attribute(:created?, true))
      end

      update(:toggle) do
        require_atomic?(false)

        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :collapsed?, !changeset.data.collapsed?)
        end)
      end

      update(:atomic_toggle) do
        change(atomic_update(:collapsed?, expr(not collapsed?)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(button(:toggle, [type: :button, on_click: :toggle], [text(name)]))
      )
    end
  end

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      notifiers: [ParentNotifier],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:folds, {:array, Fold}, allow_nil?: false, default: [], public?: true)
      attribute(:current_fold, Fold, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:update])

      action :ping, :string do
        run(fn _input, _context -> {:ok, "pong"} end)
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(render(Fold, current_fold)))
    end
  end

  test "binding resolution addresses a scalar embedded instance through its parent path" do
    page = seed(%{current_fold: %Fold{name: "scalar", collapsed?: false}})
    table = AshUi.Patch.Compiler.table(Page)
    [{child_addr, child_table}] = Map.to_list(table.children)
    [{button_addr, _entry}] = Map.to_list(child_table.event_elements)

    key =
      Enum.join(
        [
          AshUi.Patch.Compiler.addr_component(child_addr),
          AshUi.Patch.Compiler.addr_component(button_addr),
          "click"
        ],
        "."
      )

    assert {:ok, %AshUi.EventBinding{ui_event: :toggle},
            {:embedded, ^page, [:current_fold]}} =
             AshUi.Patch.Bindings.resolve(page, key)
  end

  test "embedded dispatch updates the parent row and reload sees it" do
    page = seed(%{folds: [%Fold{name: "left", collapsed?: false}]})
    flush_notifications()

    updated = embedded_dispatch!(page, [:folds, {:item, "left"}], :toggle, %{})

    assert [%Fold{name: "left", collapsed?: true}] = updated.folds
    assert [%Fold{name: "left", collapsed?: true}] = reload(page).folds
  end

  test "a scalar embedded dispatch sets the parent attribute" do
    page = seed(%{current_fold: %Fold{name: "scalar", collapsed?: false}})
    flush_notifications()

    updated = embedded_dispatch!(page, [:current_fold], :toggle, %{})

    assert %Fold{name: "scalar", collapsed?: true} = updated.current_fold
    assert %Fold{name: "scalar", collapsed?: true} = reload(page).current_fold
  end

  test "an absent primary key inserts defaults with the action applied" do
    page = seed(%{folds: []})
    flush_notifications()

    updated = embedded_dispatch!(page, [:folds, {:item, "new"}], :toggle, %{})

    assert [%Fold{name: "new", collapsed?: true, created?: true}] = updated.folds
    assert [%Fold{name: "new", collapsed?: true, created?: true}] = reload(page).folds
  end

  test "embedded dispatch emits exactly one parent update notification" do
    page = seed(%{folds: [%Fold{name: "only", collapsed?: false}]})
    flush_notifications()

    _updated = embedded_dispatch!(page, [:folds, {:item, "only"}], :toggle, %{})

    assert_receive {:parent_notification, %Ash.Notifier.Notification{action: %{type: :update}}}
    refute_receive {:parent_notification, _notification}, 50
  end

  test "embedded atomics surface Ash's unsupported-atomic error instead of being reimplemented" do
    page = seed(%{folds: [%Fold{name: "atomic", collapsed?: false}]})

    assert {:error, %Ash.Error.Invalid{} = error} =
             AshUi.Patch.Dispatch.run(
               page,
               {:embedded, page, [:folds, {:item, "atomic"}]},
               :atomic_toggle,
               %{},
               authorize?: false
             )

    assert Exception.message(error) =~ "does not support atomics on update actions"
    assert [%Fold{collapsed?: false}] = reload(page).folds
  end

  test "embedded destroy removes the addressed item through one parent update" do
    page = seed(%{folds: [%Fold{name: "left"}, %Fold{name: "right"}]})
    flush_notifications()

    assert {:ok, updated} =
             AshUi.Patch.Dispatch.run(
               page,
               {:embedded, page, [:folds, {:item, "left"}]},
               :destroy,
               %{},
               actor: self(),
               authorize?: false
             )

    assert Enum.map(updated.folds, & &1.name) == ["right"]
    assert Enum.map(reload(page).folds, & &1.name) == ["right"]
    assert_receive {:parent_notification, %Ash.Notifier.Notification{action: %{type: :update}}}
    refute_receive {:parent_notification, _notification}, 50
  end

  test "generic instance actions execute and preserve the owning record" do
    page = seed(%{})

    assert {:ok, ^page} =
             AshUi.Patch.Dispatch.run(page, {:root}, :ping, %{}, authorize?: false)
  end

  defp seed(attrs) do
    Ash.Seed.seed!(Page, Map.put(attrs, :session_id, Ash.UUID.generate()))
  end

  defp embedded_dispatch!(record, path, action, params) do
    {:ok, updated} =
      AshUi.Patch.Dispatch.embedded_update(record, path, action, params,
        actor: self(),
        authorize?: false
      )

    updated
  end

  defp reload(page) do
    Ash.get!(Page, page.session_id,
      authorize?: false,
      domain: AshUi.AshDomainFallback
    )
  end

  defp flush_notifications do
    receive do
      {:parent_notification, _notification} -> flush_notifications()
    after
      0 -> :ok
    end
  end
end
