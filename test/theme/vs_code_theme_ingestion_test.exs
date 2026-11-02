defmodule AshUi.Theme.VSCodeThemeIngestionTest do
  # VS Code theme JSON ingestion is a build-side STYLESHEET GENERATOR
  # (DESIGN §9): theme JSON in, CSS text out, WCAG gates retained. It does
  # not participate in rendering and produces no theme value.
  use ExUnit.Case, async: true

  alias AshUi.Theme.VSCode

  @fixtures Path.expand("../fixtures/vscode_themes", __DIR__)
  @dark_plus Path.join(@fixtures, "dark_plus.json")
  @light_plus Path.join(@fixtures, "light_plus.json")

  test "ingests Dark+ and Light+ fixtures with include resolution and contrast verification" do
    dark = VSCode.load_file!(@dark_plus)
    light = VSCode.load_file!(@light_plus)

    assert dark["colors"]["editor.background"] == "#1E1E1E"
    assert light["colors"]["editor.background"] == "#FFFFFF"

    assert VSCode.contrast_errors(dark) == []
    assert VSCode.contrast_errors(light) == []
  end

  test "stylesheet_from_file! returns generated CSS text gated on contrast" do
    css = VSCode.stylesheet_from_file!(@dark_plus)

    assert is_binary(css)
    assert css =~ "--vscode-editor-background: #1E1E1E;"
    refute css =~ "@import"
  end

  test "stylesheet exposes vscode tokens generic aliases workbench mappings and TextMate scopes" do
    css = @dark_plus |> VSCode.load_file!() |> VSCode.stylesheet!()

    assert css =~ "--vscode-editor-background: #1E1E1E;"
    assert css =~ "--surface: var(--vscode-editor-background);"
    assert css =~ "--ink: var(--vscode-editor-foreground);"
    assert css =~ ~s([part="list"], .workbench-list)
    assert css =~ "var(--vscode-list-inactiveSelectionBackground"
    assert css =~ ~s([part="side_bar"], .workbench-sideBar)
    assert css =~ ~s([part="quick_input"], .workbench-quickInput)
    assert css =~ ~s([part="input"], .workbench-input)
    assert css =~ ~s([part="button"], .workbench-button)
    assert css =~ ~s([part="code_block"] [data-tm-scope~="keyword.control"])
    assert css =~ ".tm-keyword-control"
  end

  test "contrast verification fails loud for declared violations" do
    bad = %{
      "name" => "bad",
      "colors" => %{
        "editor.foreground" => "#777777",
        "editor.background" => "#777777"
      }
    }

    assert [error] = VSCode.contrast_errors(bad)
    assert error =~ "editor"

    assert_raise ArgumentError, ~r/fails contrast/, fn ->
      VSCode.verify_contrast!(bad)
    end
  end

  test "the generator has no render coupling: no theme value constructors remain" do
    refute function_exported?(VSCode, :from_file!, 1)
    refute function_exported?(VSCode, :from_file!, 2)
    refute function_exported?(VSCode, :from_json!, 1)
    refute function_exported?(VSCode, :from_json!, 2)
    refute Code.ensure_loaded?(AshUi.ThemeBlueprint)
    refute Code.ensure_loaded?(AshUi.Theme)
  end
end
