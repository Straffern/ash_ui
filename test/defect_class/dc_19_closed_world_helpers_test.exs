defmodule AshUi.DefectClass.DC19ClosedWorldHelpersTest do
  use ExUnit.Case, async: false
  import AshUi.Expr
  alias AshUi.Expr.Eval, as: ExprEval
  alias AshUi.Expr.Scope, as: ExprScope
  alias AshUi.RenderTarget.Html
  alias AshUi.Runtime.Rendering

  defmodule ConstructorFixturePage do
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
      attribute(:title, :string, default: "")
      attribute(:items, {:array, :map}, default: [])
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :label,
        :term,
        {AshUi.ExportCalculation,
         export: :label,
         name: :label,
         expr: expr("Label: " <> coalesce(title, "Untitled")),
         type: :term,
         constraints: [],
         allow_nil?: true},
        public?: true,
        description: "[opaque] test fixture — shape immaterial here"
      )

      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(box([data: [count: count(items)]], [text("Label: " <> default(title, "Untitled"))]))
      )
    end
  end

  defmodule BlankRenderPage do
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
      attribute(:title, :term)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(el("div", [title: title], [text(title)]))
      )
    end
  end

  test "unknown direct expression call raises a located DslError" do
    page = unique_module([UnknownCallPage])

    error =
      assert_compile_dsl_error(page, "defmodule #{inspect(page)} do
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
    attribute(:title, :string, default: \"\")
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text(unknown_label(title))))
  end
end
")

    assert_located(error, page, ["view", "calculations"])
    assert Exception.message(error) =~ "unknown expression call unknown_label/1"
  end

  test "registered custom expression arity mismatch raises a located DslError" do
    page = unique_module([BadArityPage])

    error =
      assert_compile_dsl_error(page, "defmodule #{inspect(page)} do
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
    attribute(:title, :string, default: \"\")
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text(present?(title, \"!\"))))
  end
end
")

    assert_located(error, page, ["view", "calculations"])
    assert Exception.message(error) =~ "unknown expression call present?/2"
  end

  test "persisted constructor fixture contains no helper or runtime_call markers" do
    resource = AshUi.compile!(ConstructorFixturePage)
    terms = walk_terms(resource)

    refute Enum.any?(terms, &helper_marker?/1)
    refute Enum.any?(terms, &runtime_call_marker?/1)
  end

  test "persisted blueprint terms contain no runtime_call marker" do
    resources =
      [ConstructorFixturePage, BlankRenderPage]
      |> Enum.concat(loaded_agent_fixtures())
      |> Enum.map(&AshUi.compile!/1)

    terms = Enum.flat_map(resources, &walk_terms/1)
    refute Enum.any?(terms, &runtime_call_marker?/1)
  end

  test "deleted composition vocabulary is absent from implementation sources" do
    source =
      [Path.expand("../../lib", __DIR__), Path.expand("../../packages", __DIR__)]
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.{ex,exs}")))
      |> Enum.map_join("\n", &File.read!/1)

    for deleted <- [
          "kind: :slot",
          "kind: :fill",
          "slot_fill",
          "fill_bindings",
          "rewrite_fill_binding"
        ] do
      refute source =~ deleted
    end
  end

  test "runtime_call authored form raises as a closed-world expression call with guidance" do
    page = unique_module([RuntimeCallPage])

    error =
      assert_compile_dsl_error(page, "defmodule #{inspect(page)} do
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
    attribute(:title, :string, default: \"\")
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text(runtime_call(String, :upcase, [title]))))
  end
end
")

    assert_located(error, page, "ash_ui")
    assert Exception.message(error) =~ "unknown expression call runtime_call/3"
    assert Exception.message(error) =~ "Ash.CustomExpression"
    assert Exception.message(error) =~ "coalesce/2..N"
  end

  test "native call table stays within the Ash registry, registered custom expressions, and parser-level boolean syntax" do
    registry =
      MapSet.new(
        Enum.map(Ash.Filter.builtin_functions(), & &1.name()) ++
          Enum.map(Ash.Filter.builtin_operators(), & &1.operator())
      )

    custom_expressions =
      :ash
      |> Application.get_env(:custom_expressions, [])
      |> MapSet.new(& &1.name())

    # `and`/`or`/`not`/`!` are Ash expression syntax handled by
    # BooleanExpression/Not structs rather than registry entries.
    boolean_syntax = MapSet.new([:!, :not, :and, :or])

    allowed =
      registry
      |> MapSet.union(custom_expressions)
      |> MapSet.union(boolean_syntax)

    table_keys = AshUi.ExprCompiler.native_ash_calls() |> Map.keys() |> MapSet.new()

    assert MapSet.subset?(table_keys, allowed),
           "hand-invented names in @native_ash_calls: " <>
             inspect(MapSet.difference(table_keys, allowed) |> Enum.sort())
  end

  test "native null coalescing stays distinct from blank/default semantics" do
    not_loaded = %Ash.NotLoaded{field: :title, type: :attribute, resource: BlankRenderPage}

    rows = [
      {nil, false, true, true, "fallback", "fallback"},
      {"", false, true, true, "", "fallback"},
      {not_loaded, false, true, true, not_loaded, "fallback"},
      {[], true, false, true, [], "fallback"},
      {%{kind: :fragment, children: []}, true, false, true, %{kind: :fragment, children: []},
       "fallback"}
    ]

    for {raw_value, present?, blank?, empty?, coalesced, defaulted} <- rows do
      scope = ExprScope.new(%{value: raw_value}, %{})
      assert ExprEval.eval!(expr(present?(value)), scope) == present?
      assert ExprEval.eval!(expr(blank?(value)), scope) == blank?
      assert ExprEval.eval!(expr(empty?(value)), scope) == empty?
      # coalesce is compile-time rewritten to if/is_nil (not native Ash) —
      # the compiled path IS the only real path
      assert ExprEval.eval!(
               AshUi.ExprCompiler.compile!(expr(coalesce(value, "fallback"))),
               scope
             ) ==
               coalesced

      assert ExprEval.eval!(expr(default(value, "fallback")), scope) == defaulted
    end

    scope = ExprScope.new(%{value: nil, fallback: not_loaded}, %{})

    assert ExprEval.eval!(
             AshUi.ExprCompiler.compile!(expr(coalesce(value, "", fallback))),
             scope
           ) == ""

    resource = AshUi.compile!(BlankRenderPage)
    record = struct(BlankRenderPage, title: not_loaded)
    assert {:ok, tree} = Rendering.render_tree(resource, record, %{})
    assert %AshUi.RenderTree.Element{attrs: attrs, children: children} = tree
    assert Html.attrs(tree)["title"] == ""
    assert attrs[:title] == not_loaded or attrs["title"] == not_loaded
    assert [%AshUi.RenderTree.Text{content: ""}] = children
    assert {:safe, iodata} = Html.render_static(tree)
    assert IO.iodata_to_binary(iodata) == "<div part=\"div\" title=\"\"></div>"
  end

  defp assert_compile_dsl_error(module, source) do
    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end
    assert Exception.message(error) =~ inspect(module)
    error
  end

  defp assert_located(error, module, path_fragment) do
    message = Exception.message(error)
    assert message =~ inspect(module)
    assert Enum.any?(List.wrap(path_fragment), &String.contains?(message, &1))
  end

  defp unique_module(parts) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    Module.concat([__MODULE__ | parts] ++ [suffix])
  end

  defp loaded_agent_fixtures do
    [
      Module.concat(["AshAgent", "UI", "ChatPage"]),
      Module.concat(["AshAgent", "UI", "AgentsManagerPage"]),
      Module.concat(["AshAgent", "UI", "SessionNav"])
    ]
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  defp helper_marker?({:_helper, _module, _function, _args}), do: true
  defp helper_marker?(_term), do: false

  defp runtime_call_marker?({:_runtime_call, _module, _function, _args}), do: true
  defp runtime_call_marker?(_term), do: false

  defp walk_terms(term) do
    walk_terms(term, [])
  end

  defp walk_terms(%_{} = struct, acc) do
    acc = [struct | acc]
    struct |> Map.from_struct() |> Map.values() |> Enum.reduce(acc, &walk_terms/2)
  end

  defp walk_terms(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {key, value}, next_acc ->
      walk_terms(value, walk_terms(key, next_acc))
    end)
  end

  defp walk_terms(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &walk_terms/2)
  end

  defp walk_terms(tuple, acc) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.reduce([tuple | acc], &walk_terms/2)
  end

  defp walk_terms(term, acc), do: [term | acc]
end
