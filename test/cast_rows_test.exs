defmodule AshUi.CastRowsTest do
  use ExUnit.Case, async: true

  defmodule Entry do
    use Ash.Resource,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: :embedded,
      extensions: [AshUi],
      authorizers: [Ash.Policy.Authorizer]

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      attribute(:ref_uri, :string, allow_nil?: false, public?: true)
      attribute(:depth, :integer, default: 0, public?: true)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(section(:root, [], [text(ref_uri)])))
    end
  end

  test "casts raw maps into embedded structs" do
    rows =
      AshUi.cast_rows!(Entry, [%{ref_uri: "vfs://a", depth: 1}, %{"ref_uri" => "vfs://b"}])

    assert [%Entry{ref_uri: "vfs://a", depth: 1}, %Entry{ref_uri: "vfs://b", depth: 0}] = rows
  end

  test "a bad row raises with its index" do
    error =
      assert_raise ArgumentError, fn ->
        AshUi.cast_rows!(Entry, [%{ref_uri: "vfs://ok"}, %{depth: "x"}])
      end

    assert Exception.message(error) =~ "row 1"
  end
end
