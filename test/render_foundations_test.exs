defmodule AshUi.RenderFoundationsTest do
  use ExUnit.Case, async: true
  import AshUi.Expr
  import AshUi.ViewConstructor
  alias AshUi.Expr.{Eval, Registry, Scope}
  alias AshUi.RenderTarget.Html
  alias AshUi.RenderTree
  alias AshUi.Runtime.Rendering
  alias AshUi.Runtime.ResourceInfo

  defmodule ConfigPanel do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:body, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    ash_ui do
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(section(:root, [], [body])))
    end
  end

  defmodule ConfigSectionPage do
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

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(render(ConfigPanel, %{body: text("Body")}))
      )
    end
  end

  test "RenderTree Ash type validates tree value shape without existence checks" do
    tree = %RenderTree.Element{
      tag: :div,
      attrs: %{"aria-label" => "root"},
      children: [%RenderTree.Text{content: "Hello"}]
    }

    assert Ash.Type.storage_type(AshUi.Type.RenderTree) == :map
    assert Ash.Type.cast_input(AshUi.Type.RenderTree, tree, []) == {:ok, tree}
    assert Ash.Type.apply_constraints(AshUi.Type.RenderTree, tree, []) == {:ok, tree}
    assert Ash.Type.dump_to_native(AshUi.Type.RenderTree, tree, []) == {:ok, tree}

    missing_component = %{
      kind: :component,
      component: :missing_component,
      view: %{kind: :text, content: "ok"}
    }

    assert {:ok, ^missing_component} =
             Ash.Type.apply_constraints(
               AshUi.Type.RenderTree,
               missing_component,
               []
             )

    assert {:error, message: message} =
             Ash.Type.apply_constraints(
               AshUi.Type.RenderTree,
               %{kind: :element, tag: :div, children: [%{kind: :bogus}]},
               []
             )

    assert message =~ "invalid render tree"
    assert message =~ "unknown node kind"

    assert {:error, message: leaf_message} =
             Ash.Type.apply_constraints(
               AshUi.Type.RenderTree,
               %{kind: :text, content: self()},
               []
             )

    assert leaf_message =~ "text content must be"
  end

  test "RenderTree values reject class and style attributes recursively" do
    for attrs <- [
          %{"class" => "raw-class"},
          %{class: "raw-class"},
          %{"style" => "color: red"},
          %{style: "color: red"}
        ] do
      tree = %RenderTree.Fragment{
        children: [
          %RenderTree.Element{
            tag: :div,
            children: [%RenderTree.Element{tag: :span, attrs: attrs}]
          }
        ]
      }

      assert {:error, message: message} =
               Ash.Type.apply_constraints(AshUi.Type.RenderTree, tree, [])

      assert message =~ "class and style attributes are forbidden"
      assert message =~ "$.children[0].children[0].attrs"
    end
  end

  test "registry keeps only AshUi irreducible helpers and delegates native/custom calls" do
    removed =
      ~w(coalesce if is_nil ! not == != < <= > >= + - * / <> in and or || humanize relative_time time_ago_in_words truncate strip_prefix __class_join__)a

    for name <- removed do
      refute Registry.stdlib_name?(name), "#{inspect(name)} should not be Registry stdlib"
    end

    kept = ~w(item index event part_id result errors path_for)a

    deleted =
      ~w(read read_status export context source state state_path prop payload dom route_param command_result has_errors arg child)a

    for name <- kept do
      assert Registry.accessor_name?(name), "#{inspect(name)} should remain a Registry accessor"
    end

    for name <- deleted do
      refute Registry.accessor_name?(name),
             "#{inspect(name)} should be removed from Registry accessors"
    end

    refute Registry.stdlib_name?(:present?)
    assert AshUi.Expressions.Present in AshUi.Expressions.canonical()
    compiled = AshUi.ExprCompiler.compile!(expr(humanize("created_at")))
    assert {:ok, "created at"} = Eval.eval(compiled, Scope.new(%{}, %{}))
  end

  test "config section renders value components and emits bare part" do
    record = Ash.Seed.seed!(ConfigSectionPage, %{session_id: Ash.UUID.generate()})

    assert {:ok, %RenderTree.Element{} = tree} =
             Rendering.render_tree(ResourceInfo.compiled_resource(ConfigSectionPage), record, %{})

    attrs = Html.attrs(tree)
    assert attrs["part"] == "root"
  end

  test "HTML target infers bare part from explicit part, semantic node, and tag" do
    assert %{"part" => "cta"} =
             Html.attrs(%RenderTree.Element{tag: :button, meta: %{part: :cta}, children: []})

    assert %{"part" => "heading"} =
             Html.attrs(%RenderTree.Element{
               tag: :h1,
               meta: %{semantic: {:heading, :heading}},
               children: []
             })

    assert %{"part" => "span"} = Html.attrs(%RenderTree.Element{tag: :span, children: []})
  end
end
