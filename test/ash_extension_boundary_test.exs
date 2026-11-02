defmodule AshUi.AshExtensionBoundaryTest do
  use ExUnit.Case, async: false
  import AshUi.Expr
  alias Ash.Query.Call
  alias AshUi.Expr.Eval, as: ExprEval
  alias AshUi.Expr.Scope, as: ExprScope
  @repo_root Path.expand("..", __DIR__)
  defmodule PlainAshResource do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded

    attributes do
      attribute(:title, :string, public?: true)
    end
  end

  defmodule ChildPage do
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
      attribute(:label, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end
  end

  defmodule BoundaryPage do
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
      attribute(:id, :string, public?: true)
      attribute(:title, :string, public?: true)

      attribute(:profile, :map,
        public?: true,
        description: "[opaque] test fixture — shape immaterial here"
      )

      attribute(:artists, {:array, :string}, public?: true)
      attribute(:label, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end
  end

  test "product code does not vendor or monkey-patch Ash namespace modules" do
    assert [] == Path.wildcard(Path.join(@repo_root, "lib/ash/**/*"))
    product_files = ["mix.exs" | Path.wildcard(Path.join(@repo_root, "lib/**/*.ex"))]

    violations =
      Enum.flat_map(product_files, fn file ->
        source = File.read!(file)
        relative = Path.relative_to(file, @repo_root)

        [
          if String.contains?(source, "ignore_module_conflict") do
            {relative, "ignore_module_conflict"}
          end,
          if Regex.match?(~r/\bdefmodule\s+Ash\./, source) do
            {relative, "defmodule Ash."}
          end,
          if String.contains?(source, "local Ash module overrides") do
            {relative, "local Ash module overrides"}
          end
        ]
        |> Enum.reject(&is_nil/1)
      end)

    assert [] == violations
  end

  test "AshUi evaluates stock Ash query-function structs through Ash" do
    expression =
      AshUi.ExprCompiler.compile!(
        %Call{
          name: :fragment,
          args: [&String.replace/3, {:_ref, [], :value}, "\n", "\u2028"],
          operator?: false,
          relationship_path: []
        },
        strict_calls?: true
      )

    assert ExprEval.eval!(expression, ExprScope.new(%{value: "first\nsecond"}, %{})) ==
             "first\u2028second"

    split =
      AshUi.ExprCompiler.compile!(
        %Call{
          name: :string_split,
          args: [{:_ref, [], :value}, "\n"],
          operator?: false,
          relationship_path: []
        },
        strict_calls?: true
      )

    assert ExprEval.eval!(split, ExprScope.new(%{value: "first\nsecond"}, %{})) == [
             "first",
             "second"
           ]

    round =
      %Call{name: :round, args: [1.25, 1], operator?: false, relationship_path: []}
      |> AshUi.ExprCompiler.compile!(strict_calls?: true)
      |> AshUi.ExprCompiler.finalize_calls!(strict_calls?: true)

    assert ExprEval.eval!(round, ExprScope.new(%{}, %{})) == 1.3
  end

  test "upstream Ash.Expr expressions compile and evaluate without AshUi rewrites" do
    require Ash.Expr
    expression = Ash.Expr.expr(title == "Ada" and not is_nil(title))

    assert {:ok, true} =
             Ash.Expr.eval(expression, record: %{title: "Ada"}, resource: PlainAshResource)

    assert Ash.Expr.expr?(Ash.Expr.expr(^Ash.Expr.ref(:title) == ^Ash.Expr.arg(:title)))
    assert Ash.Expr.expr?(Ash.Expr.expr(^Ash.Expr.context(:enabled?) == true))
    assert Ash.Expr.expr?(Ash.Expr.expr(fragment("lower(?)", title)))
    assert Ash.Expr.expr?(Ash.Expr.expr(exists(comments, title == "draft")))
    assert Ash.Expr.expr?(Ash.Expr.expr(parent(title)))
    assert Ash.Expr.expr?(Ash.Expr.expr(^Ash.Expr.atomic_ref(:title)))
    raw_blueprint_helper = Ash.Expr.expr(route_param(:tab))
    assert %Call{name: :route_param, args: [:tab]} = raw_blueprint_helper

    assert {:error, %Ash.Error.Query.NoSuchFunction{function: :route_param}} =
             Ash.Expr.eval(raw_blueprint_helper,
               context: %{route: %{tab: "artists"}},
               resource: PlainAshResource
             )
  end

  test "AshUi.Expr owns AshUi helper recognition and runtime evaluation" do
    record = %{
      id: "42",
      title: "Ada",
      profile: %{name: "Lovelace"},
      artists: ["Ada"],
      label: "Featured",
      badge: %ChildPage{label: "VIP"}
    }

    opts = [
      ash_resource_module: BoundaryPage,
      item_bindings: %{artist: %{name: "Ada"}},
      index_bindings: %{artist: 2},
      part_ids: %{header: "header-1"},
      command_result: %{id: 7},
      errors: [%{field: :title, message: "attribute title is required"}]
    ]

    assert {:ok, "Ada-suffix-42"} =
             evaluate(
               expr(title <> "-" <> arg(:suffix) <> "-" <> id),
               record,
               %{suffix: "suffix"},
               opts
             )

    assert {:ok, "Lovelace"} = evaluate(expr(path(profile, [:name])), record, %{}, opts)
    assert {:ok, ["Ada"]} = evaluate(expr(artists), record, %{}, opts)
    assert {:ok, %{id: 7}} = evaluate(expr(result()), record, %{}, opts)
    assert {:ok, 7} = evaluate(expr(result(:id)), record, %{}, opts)

    assert {:ok, [%{field: :title, message: "attribute title is required"}]} =
             evaluate(expr(errors()), record, %{}, opts)

    assert {:ok, ["is required"]} =
             evaluate(expr(field_errors(errors(), :title)), record, %{}, opts)

    assert {:ok, ["is required"]} = evaluate(expr(field_errors(:title)), record, %{}, opts)

    exception_opts =
      Keyword.put(opts, :errors, [
        struct(Ash.Error.Changes.Required,
          field: :title,
          type: :attribute,
          resource: BoundaryPage,
          bread_crumbs: [
            "Error returned from: BoundaryPage.save",
            "Error returned from: ChildPage.create"
          ]
        )
      ])

    assert {:ok, ["is required"]} =
             evaluate(expr(field_errors(:title)), record, %{}, exception_opts)

    assert {:ok, "Featured"} = evaluate(expr(label), record, %{}, opts)
    assert {:ok, {:event, :value}} = evaluate(expr(event(:value)), record, %{}, opts)
    assert {:ok, "Ada"} = evaluate(expr(item(:artist, :name)), record, %{}, opts)
    assert {:ok, 2} = evaluate(expr(index(:artist)), record, %{}, opts)
    assert {:ok, "header-1"} = evaluate(expr(part_id(:header)), record, %{}, opts)

    # path_for died with the App model — evaluation reports the deletion.
    assert {:error, %ArgumentError{message: path_for_message}} =
             evaluate(
               expr(path_for(DeletedBoundaryApp, :show, %{id: id})),
               record,
               %{},
               opts
             )

    assert path_for_message =~ "path_for/3 is not supported"

    assert {:ok, false} =
             evaluate(
               expr(can(:update, %{resource: BoundaryPage})),
               record,
               %{},
               opts
             )
  end

  test "unsupported remote calls fail in AshUi.Expr, while Ash.Expr helpers are allowed" do
    assert_raise ArgumentError, ~r"unsupported remote expr call String\.upcase/1", fn ->
      AshUi.Expr.expand_expr_ast(
        quote do
          String.upcase(title)
        end,
        __ENV__
      )
    end

    {expression, _binding} =
      Code.eval_quoted(
        AshUi.Expr.expand_expr_ast(
          quote do
            Ash.Expr.fragment("lower(?)", ^Ash.Expr.ref(:title))
          end,
          __ENV__
        ),
        [],
        __ENV__
      )

    assert Ash.Expr.expr?(expression)
  end

  test "future AshUi expression modules must use Ash custom expression extension points" do
    expression_files =
      Path.wildcard(Path.join(@repo_root, "lib/ash_ui/expressions/**/*.ex")) ++
        Path.wildcard(Path.join(@repo_root, "test/support/ash_ui/expressions/**/*.ex"))

    violations =
      expression_files
      |> Enum.reject(fn file ->
        source = File.read!(file)

        String.contains?(source, "use Ash.CustomExpression") and
          String.contains?(source, "def expression(") and String.contains?(source, ":unknown")
      end)
      |> Enum.map(&Path.relative_to(&1, @repo_root))

    assert [] == violations
  end

  test "registered AshUi custom expressions are usable through upstream Ash.Expr" do
    require Ash.Expr
    expression = Ash.Expr.expr(blueprint_test_text_length(title) == 3)

    assert {:ok, true} =
             Ash.Expr.eval(expression, record: %{title: "Ada"}, resource: PlainAshResource)

    assert :unknown =
             Ash.CustomExpression.expression(
               AshUi.Expressions.TestTextLength,
               UnsupportedDataLayer,
               ["Ada"]
             )
  end

  defp evaluate(expression, record, params, opts) do
    ExprEval.eval(expression, ExprScope.new(record, params, opts))
  end
end
