defmodule AshUi.DefectClass.OneParserTest do
  use ExUnit.Case, async: false
  import AshUi.ViewConstructor

  @lib_root Path.expand("../../lib", __DIR__)

  defmodule SharedBadge do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, public?: true)
      attribute(:body, AshUi.Type.RenderTree, public?: true)
    end

    actions do
      action(:select, :map) do
        argument(:id, :string, allow_nil?: false)
        run(fn _input, _context -> {:ok, %{}} end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          button(:badge_root, [action_input: %{id: label}, on_click: :select], [
            text(label),
            body
          ])
        )
      )
    end
  end

  defmodule InlineBadge do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, public?: true)
      attribute(:body, AshUi.Type.RenderTree, public?: true)
    end

    actions do
      action(:select, :map) do
        argument(:id, :string, allow_nil?: false)
        run(fn _input, _context -> {:ok, %{}} end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          button(:badge_root, [action_input: %{id: label}, on_click: :select], [
            text(label),
            body
          ])
        )
      )
    end
  end

  test "DC-15 source scan has no deleted capture channels" do
    source = lib_source()
    refute source =~ ~r"\bProcess.(put|get)\b"

    for symbol <- [
          "parse_template!",
          "ash_ui_initial_attributes",
          "initial_attribute_entries",
          "draft_metadata",
          "draft?",
          "__put_blueprint_config__"
        ] do
      refute source =~ symbol
    end
  end

  test "DC-15 value resources share the same compiled parser output" do
    assert semantic_resource(AshUi.compile!(SharedBadge)) ==
             semantic_resource(AshUi.compile!(InlineBadge))
  end

  defp semantic_resource(resource) do
    resource.view
  end

  defp lib_source do
    @lib_root |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.map_join("\n", &File.read!/1)
  end
end
