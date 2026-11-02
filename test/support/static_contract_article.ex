defmodule AshUi.TestSupport.StaticContractArticle do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshUi],
    validate_domain_inclusion?: false

  ets do
    private?(true)
  end

  ash_ui do
  end

  resource do
    short_name(:contract_article)
  end

  attributes do
    attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
    attribute(:title, :string, allow_nil?: false)
    attribute(:published, :boolean, default: false)
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  actions do
    create(:create) do
      argument(:title, :string, allow_nil?: false)
    end

    update(:publish) do
      argument(:published, :boolean, allow_nil?: false)
    end

    destroy(:remove)
  end
end
