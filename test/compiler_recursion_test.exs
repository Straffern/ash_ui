defmodule AshUi.CompilerRecursionTest do
  use ExUnit.Case, async: false

  defmodule RecursiveSelfReader do
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
      short_name(:recursive_self_reader)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:query, :string)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])
    end

    relationships do
      has_many(:self_lookup, __MODULE__) do
        no_attributes?(true)
        read_action(:read)
      end
    end
  end

  defmodule MutualReadLeft do
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
      short_name(:mutual_read_left)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:query, :string)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])
    end

    relationships do
      has_many(:right_lookup, AshUi.CompilerRecursionTest.MutualReadRight) do
        no_attributes?(true)
        read_action(:read)
      end
    end
  end

  defmodule MutualReadRight do
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
      short_name(:mutual_read_right)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:query, :string)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])
    end

    relationships do
      has_many(:left_lookup, AshUi.CompilerRecursionTest.MutualReadLeft) do
        no_attributes?(true)
        read_action(:read)
      end
    end
  end

  test "self-referential relationship normalization short-circuits recursive compilation" do
    normalized = AshUi.compile!(RecursiveSelfReader)
    self_lookup = Enum.find(normalized.relationships, &(&1.name == :self_lookup))
    assert self_lookup.destination_kind == :static
    assert self_lookup.destination == RecursiveSelfReader
    assert is_nil(self_lookup.destination_resource)
  end

  test "mutually referential relationships compile without looping forever" do
    normalized = AshUi.compile!(MutualReadLeft)
    right_lookup = Enum.find(normalized.relationships, &(&1.name == :right_lookup))

    left_lookup =
      Enum.find(right_lookup.destination_resource.relationships, &(&1.name == :left_lookup))

    assert right_lookup.destination_kind == :static
    assert right_lookup.destination == MutualReadRight
    assert right_lookup.destination_resource.name == :mutual_read_right
    assert left_lookup.destination_kind == :static
    assert left_lookup.destination == MutualReadLeft
    assert is_nil(left_lookup.destination_resource)
  end
end
