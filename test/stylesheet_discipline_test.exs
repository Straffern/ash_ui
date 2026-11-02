defmodule AshUi.StylesheetDisciplineTest do
  # DESIGN §9 compile-time discipline: every violation is a TEACHING error —
  # it states what is wrong, why the rule exists, shows the correct procedure
  # with a concrete example, and points at DESIGN.md §9. These tests
  # trigger each error with real probe code and assert the teaching content.
  use ExUnit.Case, async: false

  defmodule StylesheetSupplier do
    @moduledoc false

    defmodule Transformer do
      use Spark.Dsl.Transformer

      def before?(AshUi.Transformers.PersistStaticBlueprint), do: true
      def before?(_other), do: false

      def transform(dsl_state) do
        {:ok,
         Spark.Dsl.Transformer.persist(
           dsl_state,
           {:ash_ui, :supplied_stylesheets},
           ["test/support/assets/dc_43.css"]
         )}
      end
    end

    use Spark.Dsl.Extension, transformers: [Transformer]
  end

  test "routed resource without stylesheets is a teaching compile error" do
    message =
      assert_teaching_error("""
      #{page_header(unique_module(MissingSheetsPage), "routes do\n  route(\"/probe\")\nend")}
        calculations do
          calculate(:view, AshUi.Type.RenderTree, expr(text("ok")))
        end
      end
      """)

    assert message =~ "declares routes but no stylesheets"
    assert message =~ "must declare its stylesheets"
    assert message =~ ~s(stylesheets ["assets/css/theme.css", "assets/css/app.css"])
    assert message =~ "no default stylesheets and no runtime fallbacks"
    assert message =~ "DESIGN.md §9"
  end

  test "supplied plus locally declared stylesheets is a teaching compile error" do
    module = unique_module(SuppliedConflictPage)

    message =
      assert_teaching_error("""
      #{page_header(module, "routes do\n  route(\"/probe\")\nend", extra_extensions: [__MODULE__.StylesheetSupplier], stylesheets: ~s(["test/support/assets/dc_43.css"]))}
        calculations do
          calculate(
            :view,
            AshUi.Type.RenderTree,
            expr(box(:shell_root, [], [text("ok")]))
          )
        end
      end
      """)

    assert message =~ "declares stylesheets locally AND receives supplied stylesheets"
    assert message =~ "ONE assembly channel"
    assert message =~ "Substrate supplied:"
    assert message =~ "Locally declared:"
    assert message =~ "Remove the local declaration"
    assert message =~ "DESIGN.md §9"
  end

  test "non-routed component declaring stylesheets is a teaching compile error" do
    message =
      assert_teaching_error("""
      #{page_header(unique_module(ComponentSheetsPage), nil, stylesheets: ~s(["test/support/assets/dc_43.css"]))}
        calculations do
          calculate(:view, AshUi.Type.RenderTree, expr(text("ok")))
        end
      end
      """)

    assert message =~ "declares stylesheets but no routes"
    assert message =~ "covered by the stylesheets of every page that mounts it"
    assert message =~ "Remove the declaration from this component"
    assert message =~ ~s(stylesheets ["assets/css/theme.css", "assets/css/app.css"])
    assert message =~ "DESIGN.md §9"
  end

  test "uncovered emitted parts are a teaching compile error listing parts and sheets" do
    message =
      assert_teaching_error("""
      #{page_header(unique_module(UncoveredPartsPage), "routes do\n  route(\"/probe\")\nend", stylesheets: ~s(["test/support/assets/uncovered_probe.css"]))}
        calculations do
          calculate(
            :view,
            AshUi.Type.RenderTree,
            expr(box(:uncovered_part, [], [text("ok")]))
          )
        end
      end
      """)

    assert message =~ "emits parts with no [part=...] rule"
    assert message =~ "Uncovered parts (1):"
    assert message =~ "uncovered_part"
    assert message =~ "Stylesheets scanned:"
    assert message =~ "test/support/assets/uncovered_probe.css"
    assert message =~ ~s([part="uncovered_part"] { /* paint */ })
    assert message =~ "DESIGN.md §9"
  end

  test "@import inside a declared stylesheet is a teaching compile error" do
    message =
      assert_teaching_error("""
      #{page_header(unique_module(ImportSheetPage), "routes do\n  route(\"/probe\")\nend", stylesheets: ~s(["test/support/assets/import_probe.css"]))}
        calculations do
          calculate(
            :view,
            AshUi.Type.RenderTree,
            expr(box(:shell_root, [], [text("ok")]))
          )
        end
      end
      """)

    assert message =~ "uses @import"
    assert message =~ "test/support/assets/import_probe.css:2"
    assert message =~ "SOLE import order"
    assert message =~ "declare the imported file as its own entry"
    assert message =~ "DESIGN.md §9"
  end

  test "missing declared stylesheet file is a teaching compile error" do
    message =
      assert_teaching_error("""
      #{page_header(unique_module(MissingFilePage), "routes do\n  route(\"/probe\")\nend", stylesheets: ~s(["test/support/assets/does_not_exist.css"]))}
        calculations do
          calculate(:view, AshUi.Type.RenderTree, expr(text("ok")))
        end
      end
      """)

    assert message =~ "does not exist or is unreadable"
    assert message =~ "test/support/assets/does_not_exist.css"
    assert message =~ "must be generated BEFORE those resources compile"
    assert message =~ ~s(stylesheets ["assets/css/theme.css", "assets/css/app.css"])
    assert message =~ "DESIGN.md §9"
  end

  test "an authored class attribute on a view node is a teaching compile error" do
    message =
      assert_teaching_error("""
      #{page_header(unique_module(RawClassPage), nil)}
        calculations do
          calculate(
            :view,
            AshUi.Type.RenderTree,
            expr(box(:card, [class: "oops"], [text("ok")]))
          )
        end
      end
      """)

    assert message =~ "authors a raw `class` attribute"
    assert message =~ "Structure and paint are strictly split"
    assert message =~ "coverage verifier cannot see"
    assert message =~ ~s([part="artist_card"][aria-selected="true"])
    assert message =~ "generated_class: :typed_icon_name"
    assert message =~ "DESIGN.md §9"
  end

  test "the @import scanner is comment- and string-aware" do
    %{parts: parts, imports: imports} =
      AshUi.Verifiers.StylesheetCoverage.scan_css("""
      /* @import "not-real.css"; [part="commented_out"] */
      [part="double"] { content: '@import "still-a-string.css"'; }
      [ part = 'single' ] { color: red; }
      [part=bare] { color: red; }
      [part^="prefix_match_does_not_count"] { color: red; }
      """)

    assert MapSet.equal?(parts, MapSet.new(["double", "single", "bare"]))
    assert imports == []

    assert %{imports: [3]} =
             AshUi.Verifiers.StylesheetCoverage.scan_css("""
             [part="x"] { color: red; }
             /* comment */
             @import url("hidden.css");
             """)
  end

  defp assert_teaching_error(source) do
    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end

    # The Spark error formatter re-wraps lines; normalize whitespace so the
    # asserted teaching phrases match regardless of wrap position.
    error
    |> Exception.message()
    |> String.replace(~r/\s+/, " ")
  end

  defp page_header(module, routes_block, opts \\ []) do
    extensions =
      [AshUi | Keyword.get(opts, :extra_extensions, [])]
      |> Enum.map_join(", ", &inspect/1)

    stylesheets =
      case Keyword.get(opts, :stylesheets) do
        nil -> ""
        sheets -> "  ash_ui do\n    stylesheets(#{sheets})\n  end\n"
      end

    """
    defmodule #{inspect(module)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [#{extensions}],
        validate_domain_inclusion?: false

      ets do
        private?(true)
      end

    #{stylesheets}
      #{routes_block || ""}

      attributes do
        attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      end

      identities do
        identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
      end
    """
  end

  defp unique_module(name) do
    Module.concat([__MODULE__, name, "P#{System.unique_integer([:positive])}"])
  end
end
