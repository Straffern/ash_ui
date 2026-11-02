defmodule AshUi.PatchFixtures.Fold do
  @moduledoc false
  use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

  attributes do
    attribute(:message_id, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:expanded?, :boolean, allow_nil?: false, default: false, public?: true)
  end

  actions do
    # read+destroy are required: pk-merge array casting reads existing
    # elements and destroys removed ones; create/update must accept the
    # cast fields (standard Ash embedded semantics).
    defaults([:read, :destroy, create: :*, update: :*])

    update :toggle do
      change(atomic_update(:expanded?, expr(not expanded?)))
    end
  end
end

defmodule AshUi.PatchFixtures.Page do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshUi],
    validate_domain_inclusion?: false,
    notifiers: [AshUi.Notifier]

  alias AshUi.PatchFixtures.Fold

  ets do
    private?(true)
  end

  attributes do
    attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
    attribute(:selected_id, :string, allow_nil?: false, default: "none", public?: true)
    attribute(:title, :string, allow_nil?: false, default: "Inbox", public?: true)

    attribute(:folds, {:array, Fold}, allow_nil?: false, default: [], public?: true)
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  actions do
    defaults([:read])

    create :mount do
      argument(:folds, {:array, Fold}, allow_nil?: true)
      change(set_attribute(:folds, arg(:folds), set_when_nil?: false))
    end

    update :select do
      require_atomic?(false)
      argument(:id, :string, allow_nil?: false)
      change(set_attribute(:selected_id, arg(:id)))
    end

    update :retitle do
      require_atomic?(false)
      argument(:title, :string, allow_nil?: false)
      change(set_attribute(:title, arg(:title)))
    end

    update :put_folds do
      require_atomic?(false)
      argument(:folds, {:array, Fold}, allow_nil?: false)
      change(set_attribute(:folds, arg(:folds)))
    end
  end

  calculations do
    calculate(
      :view,
      AshUi.Type.RenderTree,
      expr(
        section(:root, [part: :dc35_root], [
          heading(:title, [], [text(title)]),
          inline(:selected, [part: :dc35_selected, data: %{selected: selected_id}], [
            text(selected_id)
          ]),
          list(:folds, [part: :dc35_folds], [
            each(folds, :fold, [], [
              item(
                :row,
                [part: :dc35_fold_row, aria: %{expanded: fold.expanded?}],
                [text(fold.message_id)]
              )
            ])
          ])
        ])
      )
    )
  end
end

defmodule AshUi.PatchFixtures.Badge do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: :embedded,
    extensions: [AshUi],
    validate_domain_inclusion?: false

  attributes do
    attribute(:label, :string, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: :*])
  end

  calculations do
    calculate(
      :view,
      AshUi.Type.RenderTree,
      expr(inline(:badge, [part: :dc35_badge], [text(label)]))
    )
  end
end

defmodule AshUi.PatchFixtures.ShellPage do
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
    attribute(:badge_label, :string, allow_nil?: false, default: "new", public?: true)
    attribute(:footer, :string, allow_nil?: false, default: "f", public?: true)
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  actions do
    defaults([:read])

    create :mount do
    end

    update :relabel do
      require_atomic?(false)
      argument(:label, :string, allow_nil?: false)
      change(set_attribute(:badge_label, arg(:label)))
    end
  end

  calculations do
    calculate(
      :view,
      AshUi.Type.RenderTree,
      expr(
        section(:shell, [part: :dc35_shell], [
          render(AshUi.PatchFixtures.Badge, %{label: badge_label}),
          inline(:footer, [], [text(footer)])
        ])
      )
    )
  end
end

defmodule AshUi.PatchFixtures do
  @moduledoc false

  alias AshUi.PatchFixtures.{Fold, Page}

  def fold(id, expanded? \\ false), do: %{message_id: id, expanded?: expanded?}

  def seed(folds) do
    Ash.Seed.seed!(Page, %{
      session_id: Ash.UUID.generate(),
      folds: Enum.map(folds, &struct(Fold, &1))
    })
  end

  def run!(page, action, args) do
    page
    |> Ash.Changeset.for_update(action, args,
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)
  end

  def toggle_fold(page, id) do
    folds =
      Enum.map(page.folds, fn f ->
        if f.message_id == id, do: %{f | expanded?: not f.expanded?}, else: f
      end)

    run!(page, :put_folds, %{folds: folds})
  end
end
