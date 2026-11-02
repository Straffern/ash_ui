defmodule AshUi.AshEvaluationPipelineTest do
  use ExUnit.Case, async: true

  alias Ash.Query.{BooleanExpression, Call, Not}
  alias AshUi.Expr.{Eval, Scope}
  alias AshUi.Patch.EvalCompiler

  defmodule BooleanView do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:flag, :boolean, public?: true)
      attribute(:title, :string, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [], [
            text(not flag),
            text(title || "fallback"),
            if not flag do
              text("negated")
            else
              text("otherwise")
            end
          ])
        )
      )
    end
  end

  test "all boolean forms agree exactly with Ash, including nil and nonboolean operands" do
    for left <- [nil, false, true, "value"], right <- [nil, false, true], op <- [:and, :or] do
      expected = Ash.Expr.eval!(%BooleanExpression{op: op, left: left, right: right})
      scope = Scope.new(%{left: left, right: right}, %{})
      call = %Call{name: op, args: [{:_ref, [], :left}, {:_ref, [], :right}]}
      node = %BooleanExpression{op: op, left: {:_ref, [], :left}, right: {:_ref, [], :right}}
      assert Eval.eval!(call, scope) === expected
      assert Eval.eval!(node, scope) === expected
      assert generated(call, scope) === expected
    end

    for value <- [nil, false, true, "value"] do
      scope = Scope.new(%{value: value}, %{})
      expected = Ash.Expr.eval!(%Not{expression: value})

      for expression <- [%Not{expression: {:_ref, [], :value}}, call(:not, [{:_ref, [], :value}])] do
        assert Eval.eval!(expression, scope) === expected
        assert generated(expression, scope) === expected
      end
    end

    assert Eval.eval!(call(:not, [nil]), Scope.new(%{}, %{})) === nil
  end

  test "view conditions alone apply truthiness to the resulting Ash value" do
    for {flag, expected} <- [
          {nil, "fallbackotherwise"},
          {false, "truefallbacknegated"},
          {true, "falsefallbackotherwise"}
        ] do
      record = struct(BooleanView, flag: flag, title: "")
      resource = AshUi.Runtime.ResourceInfo.compiled_resource(BooleanView)
      assert {:ok, tree} = AshUi.Runtime.Rendering.render_tree(resource, record, %{})
      assert {:safe, html} = AshUi.RenderTarget.Html.render_static(tree)
      assert IO.iodata_to_binary(html) == "<section part=\"root\">#{expected}</section>"
    end
  end

  test "registered view helpers run through Ash with their nil and empty contracts" do
    not_loaded = %Ash.NotLoaded{field: :name, type: :attribute, resource: BooleanView}

    examples = [
      {:blank?, [nil], true},
      {:blank?, [false], false},
      {:present?, [nil], false},
      {:empty?, [[]], true},
      {:empty?, [false], false},
      {:nilif_blank, [""], nil},
      {:nilif_blank, [false], false},
      {:join, [nil, ","], ""},
      {:join, [["a", nil, "b"], ","], "a,,b"},
      {:count, [nil], 0},
      {:count, [%{a: 1}], 1},
      {:append_unique, [nil, nil], []},
      {:append_unique, [[1, 2], 2], [1, 2]},
      {:sort_by, [[%{n: 2}, %{n: nil}, %{n: 1}], [:n]], [%{n: nil}, %{n: 1}, %{n: 2}]},
      {:sort_by, [[%{n: 1}, %{n: 2}], [:n], :desc], [%{n: 2}, %{n: 1}]},
      {:find_by, [[%{n: 1}, %{n: 2}], [:n], 2], %{n: 2}},
      {:field_errors, [[%{field: :name, message: "is invalid"}], :name], ["is invalid"]},
      {:default, [nil, "fallback"], "fallback"},
      {:default, [false, "fallback"], false},
      {:default, ["", "fallback"], "fallback"},
      {:blank?, [not_loaded], true},
      {:default, [not_loaded, "fallback"], "fallback"},
      {:__class_join__, [["base", {nil, "absent"}, {false, "absent"}, {true, "active"}]],
       "base active"}
    ]

    for {name, args, expected} <- examples do
      # Also exercises the public upstream API, independent of AshUi Eval.
      {module, arguments} = Ash.Filter.custom_expression(name, args)

      assert {:ok, native} =
               Ash.CustomExpression.expression(module, Ash.DataLayer.Simple, arguments)

      assert Ash.Expr.eval!(native) === expected
      assert Eval.eval!(call(name, args), Scope.new(%{}, %{})) === expected
    end

    class_scope = Scope.new(%{enabled: false}, %{})
    classes = call(:__class_join__, [["base", {{:_ref, [], :enabled}, call(:round, [1.2, 100])}]])
    assert Eval.eval!(classes, class_scope) == "base"
  end

  test "scope errors are injected before the registered field_errors helper" do
    scope =
      Scope.new(%{}, %{},
        errors: [%{field: :name, message: "is invalid"}],
        __bp_all_errors__: [%{field: :other, message: "other"}]
      )

    assert Eval.eval!(call(:field_errors, [:name]), scope) == ["is invalid"]
    assert Eval.eval!({:_errors}, scope) == [%{field: :other, message: "other"}]
    assert generated(call(:field_errors, [:name]), scope) == ["is invalid"]
  end

  test "all scope markers become values before Ash, including deferred branches" do
    scope =
      Scope.new(%{title: "record"}, %{value: "argument"},
        actor: %{id: "actor"},
        context: %{label: "context"},
        item_bindings: %{row: %{name: "item"}},
        index_bindings: %{position: 3},
        part_ids: %{root: "root-id"},
        command_result: %{id: 7}
      )

    expression =
      call(:if, [
        true,
        [
          do: [
            {:_ref, [], :title},
            {:_arg, :value},
            {:_actor, :id},
            {:_context, :label},
            {:_item, :row, :name},
            {:_index, :position},
            {:_part_id, :root},
            {:_result, :id},
            {:_event, :value}
          ],
          else: nil
        ]
      ])

    assert Eval.eval!(expression, scope) == [
             "record",
             "argument",
             "actor",
             "context",
             "item",
             3,
             "root-id",
             7,
             {:event, :value}
           ]

    # The resolved branch must survive without its originating scope.
    resolved = Eval.resolve(expression, scope)
    assert Ash.Expr.eval!(resolved) == Eval.eval!(expression, scope)
  end

  test "If defers dead-arm hydration and execution for dynamic true false and nil" do
    for flag <- [true, false, nil],
        bad <- [call(:round, [1.2, 100]), call(:fragment, [fn -> raise "dead branch" end])] do
      condition = call(:fragment, [fn -> flag end])
      {yes, no} = if flag, do: {:safe, bad}, else: {bad, :safe}
      expression = call(:if, [condition, [do: yes, else: no]])
      assert Eval.eval!(expression, Scope.new(%{}, %{})) == :safe
    end

    expression =
      call(:if, [call(:fragment, [fn -> true end]), [do: call(:round, [1.2, 100]), else: :safe]])

    assert_raise ArgumentError, fn -> Eval.eval!(expression, Scope.new(%{}, %{})) end
  end

  test "default and its || alias bind the candidate once and defer the fallback" do
    owner = self()

    for name <- [:default, :||], candidate <- [false, "present"] do
      expression =
        call(name, [
          call(:fragment, [
            fn ->
              send(owner, :candidate)
              candidate
            end
          ]),
          call(:round, [1.2, 100])
        ])

      assert Eval.eval!(expression, Scope.new(%{}, %{})) === candidate
      assert_receive :candidate
      refute_receive :candidate, 0
    end

    for name <- [:default, :||], value <- [nil, "", [], %{kind: :fragment, children: []}] do
      assert Eval.eval!(call(name, [value, "fallback"]), Scope.new(%{}, %{})) == "fallback"
    end
  end

  test "case lowers ordered exact patterns and wildcard to Ash with one subject evaluation" do
    owner = self()

    subject =
      call(:fragment, [
        fn ->
          send(owner, :subject)
          nil
        end
      ])

    expression =
      call(:case, [
        subject,
        [
          {:unmatched, call(:round, [1.2, 100])},
          {nil, :nil_match},
          {:_, call(:round, [1.2, 100])}
        ]
      ])

    assert Eval.eval!(expression, Scope.new(%{}, %{})) == :nil_match
    assert_receive :subject
    refute_receive :subject, 0

    upper = Ash.CiString.new("VALUE")
    lower = Ash.CiString.new("value")

    assert Eval.eval!(call(:case, [upper, [{lower, :wrong}, {:_, :exact}]]), Scope.new(%{}, %{})) ==
             :exact

    assert Eval.eval!(call(:case, [:value, [{:other, :wrong}]]), Scope.new(%{}, %{})) == nil

    assert Eval.eval!(call(:case, [1, [{1, :first}, {1, :second}]]), Scope.new(%{}, %{})) ==
             :first
  end

  test "function and MFA fragments use native Ash evaluation" do
    scope = Scope.new(%{value: "ash"}, %{})
    assert Eval.eval!(call(:fragment, [&String.upcase/1, {:_ref, [], :value}]), scope) == "ASH"

    assert Eval.eval!(call(:fragment, [{String, :upcase, []}, {:_ref, [], :value}]), scope) ==
             "ASH"
  end

  defp call(name, args), do: %Call{name: name, args: args}

  defp generated(ir, scope) do
    assert {:ok, body} = EvalCompiler.compile(ir)

    {function, []} =
      Code.eval_quoted(
        quote do
          fn var!(scope, AshUi.Patch.EvalCompiler) -> unquote(body) end
        end
      )

    function.(scope)
  end
end
