defmodule AshUi.DelegatedViewExpressionsTest do
  use ExUnit.Case, async: true

  alias AshUi.Expr.Eval
  alias AshUi.Expr.Scope

  defmodule MembershipView do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:slug, :string, public?: true)
      attribute(:visible_slugs, {:array, :string}, default: [], public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(text(slug in visible_slugs))
      )
    end
  end

  defmodule StringConversionView do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:position, :integer, public?: true)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text(to_string(position))))
    end
  end

  defmodule ConcatenationView do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:prefix, :string, public?: true)
      attribute(:suffix, :string, public?: true)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text(prefix <> suffix)))
    end
  end

  test "view expressions evaluate attribute membership with in" do
    assert render_text(MembershipView, %{slug: "draft", visible_slugs: ["draft", "sent"]}) ==
             true

    assert render_text(MembershipView, %{slug: "archived", visible_slugs: ["draft", "sent"]}) ==
             false

    assert render_text(MembershipView, %{slug: nil, visible_slugs: []}) == ""
  end

  test "view expressions convert ordinary attribute values with to_string/1" do
    assert render_text(StringConversionView, %{position: 42}) == "42"
  end

  test "view expressions concatenate ordinary attribute values with <>" do
    assert render_text(ConcatenationView, %{prefix: "ash_", suffix: "ui"}) ==
             "ash_ui"
  end

  test "native in/to_string/concat exactly preserve delegated Ash nil propagation" do
    scope = Scope.new(%{value: "present", values: ["present"]}, %{})

    expressions = [
      %Ash.Query.Call{name: :<>, args: ["left", "right"], operator?: true},
      %Ash.Query.Call{name: :<>, args: [nil, "right"], operator?: true},
      %Ash.Query.Call{name: :<>, args: ["left", nil], operator?: true},
      %Ash.Query.Call{name: :<>, args: [{:_ref, [], :missing}, "right"], operator?: true},
      %Ash.Query.Call{name: :to_string, args: [42]},
      %Ash.Query.Call{name: :to_string, args: [nil]},
      %Ash.Query.Call{name: :to_string, args: [{:_ref, [], :missing}]},
      %Ash.Query.Call{
        name: :in,
        args: [{:_ref, [], :value}, {:_ref, [], :values}],
        operator?: true
      },
      %Ash.Query.Call{name: :in, args: [nil, ["present"]], operator?: true},
      %Ash.Query.Call{name: :in, args: ["present", nil], operator?: true},
      %Ash.Query.Call{
        name: :in,
        args: [{:_ref, [], :value}, {:_ref, [], :missing}],
        operator?: true
      }
    ]

    Enum.each(expressions, fn expression ->
      resolved = resolve_scope_markers(expression, scope)
      assert {:ok, delegated} = Ash.Expr.eval(resolved, unknown_on_unknown_refs?: true)
      assert Eval.eval!(expression, scope) === delegated
    end)
  end

  defp render_text(module, attrs) do
    record = struct(module, attrs)
    resource = AshUi.Runtime.ResourceInfo.compiled_resource(module)

    assert {:ok, %{kind: :text, content: content}} =
             AshUi.Runtime.Rendering.render_view(resource, record, %{})

    content
  end

  defp resolve_scope_markers(%Ash.Query.Call{args: args} = call, scope) do
    %{call | args: Enum.map(args, &resolve_scope_markers(&1, scope))}
  end

  defp resolve_scope_markers({:_ref, _path, _attribute} = marker, scope),
    do: Eval.eval!(marker, scope)

  defp resolve_scope_markers(values, scope) when is_list(values),
    do: Enum.map(values, &resolve_scope_markers(&1, scope))

  defp resolve_scope_markers(value, _scope), do: value
end
