defmodule AshUi.DefectClass.DC41CompiledEvalsTest do
  @moduledoc """
  DC-41: hot slot expressions bind to resource-generated evaluators only
  when the exact IR hash was generated. Generated values remain identical
  to the interpreter across record and keyed-item scope shapes.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias AshUi.Expr.Eval
  alias AshUi.Expr.Scope
  alias AshUi.Patch.EvalCompiler

  defmodule Row do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, public?: true)
      attribute(:meta, :map, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule Page do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:title, :string, public?: true)
      attribute(:suffix, :string, public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, create: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [], [
            text(title),
            text(title <> suffix),
            text(to_string(title)),
            if empty?(field_errors(:title)) do
              text("valid")
            else
              text("invalid")
            end,
            each(rows, :row, [index: :position, key: row.id], [
              item(:entry, [], [
                text(row.label),
                text(row.meta.label),
                text(index(:position))
              ])
            ])
          ])
        )
      )
    end
  end

  test "compiled concat and to_string match the interpreter for nil operands" do
    for {ir, record} <- [
          {%Ash.Query.Call{
             name: :<>,
             args: [{:_ref, [], :title}, {:_ref, [], :suffix}],
             operator?: true
           }, %{title: nil, suffix: "suffix"}},
          {%Ash.Query.Call{
             name: :<>,
             args: [{:_ref, [], :title}, {:_ref, [], :suffix}],
             operator?: true
           }, %{title: "title", suffix: nil}},
          {%Ash.Query.Call{name: :to_string, args: [{:_ref, [], :title}]}, %{title: nil}}
        ] do
      hash = EvalCompiler.hash(ir)
      scope = Scope.new(record, %{})

      assert MapSet.member?(Page.__bp_compiled_evals__(), hash)
      assert Page.__bp_eval__(hash, record, %{}, %{}, %{}) === Eval.eval!(ir, scope)
      assert Eval.eval!(ir, scope) === nil
    end
  end

  test "resource exports generated evaluator membership for a known view expression" do
    hash = EvalCompiler.hash({:_ref, [], :title})

    assert function_exported?(Page, :__bp_eval__, 5)
    assert function_exported?(Page, :__bp_compiled_evals__, 0)
    assert MapSet.member?(Page.__bp_compiled_evals__(), hash)
  end

  test "scope-backed field error predicates use generated evaluators" do
    ir =
      %Ash.Query.Call{
        name: :empty?,
        args: [
          %Ash.Query.Call{
            name: :field_errors,
            args: [:title],
            operator?: false,
            relationship_path: []
          }
        ],
        operator?: false,
        relationship_path: []
      }

    expression = %AshUi.Expr.Compiled{ir: ir, deps: [errors: []]}
    evaluator = AshUi.Patch.Evaluator.compile(expression, Page)

    assert is_function(evaluator, 1)

    for errors <- [[], [%{field: :title, message: "is invalid"}], [%{field: :other}]] do
      scope = Scope.new(%Page{}, %{}, errors: errors)
      assert evaluator.(scope) === Eval.eval!(ir, scope)
    end
  end

  property "compiled safe values equal interpreter values across scope shapes" do
    check all(
            title <-
              one_of([
                term(),
                constant(%Ash.NotLoaded{field: :title, type: :attribute, resource: Page})
              ]),
            label <- term(),
            nested_label <- term(),
            index <- integer(),
            string_record? <- boolean(),
            string_bindings? <- boolean(),
            args_shadow? <- boolean()
          ) do
      record = if string_record?, do: %{"title" => title}, else: %{title: title}
      binding_row = %{"label" => label, "meta" => %{"label" => nested_label}}
      shadow_row = %{"label" => {:shadow, label}, "meta" => %{"label" => {:shadow, nested_label}}}

      item_bindings =
        if string_bindings?, do: %{"row" => binding_row}, else: %{row: binding_row}

      args = if args_shadow?, do: %{"row" => shadow_row}, else: %{}
      index_bindings = %{"position" => index}

      scope =
        Scope.new(record, args,
          item_bindings: item_bindings,
          index_bindings: index_bindings
        )

      for ir <- [
            {:_ref, [], :title},
            {:_item, :row, [:label]},
            {:_item, :row, [:meta, :label]},
            {:_index, :position}
          ] do
        hash = EvalCompiler.hash(ir)
        assert MapSet.member?(Page.__bp_compiled_evals__(), hash)

        assert Page.__bp_eval__(hash, record, args, item_bindings, index_bindings) ==
                 Eval.eval!(ir, scope)
      end
    end
  end
end
