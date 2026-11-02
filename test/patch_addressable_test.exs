defmodule AshUi.PatchAddressableTest do
  @moduledoc """
  Pins the PATCH-ADDRESSABLE property (`Patch.Compiler.patch_addressable?/1`)
  — the ONE compile-time rule deciding which elements carry runtime ids.
  The id diet lives or dies by this predicate staying exact: a false
  positive re-inflates collection DOM/wire mass, a false negative strands a
  patch without a selector.
  """

  use ExUnit.Case, async: true

  alias AshUi.ExprCompiler
  alias AshUi.Patch.Compiler

  defp compiled_expr do
    ExprCompiler.compile!({:_ref, [], :title})
  end

  defp element(overrides) do
    Map.merge(%{kind: :element, tag: :div, attrs: %{}, children: []}, Map.new(overrides))
  end

  test "a fully static wrapper is not addressable" do
    refute Compiler.patch_addressable?(
             element(children: [element([]), %{kind: :text, content: "static"}])
           )
  end

  test "a dynamic attr surface makes the element addressable" do
    assert Compiler.patch_addressable?(element(attrs: %{title: compiled_expr()}))
  end

  test "an event binding makes the element addressable" do
    assert Compiler.patch_addressable?(element(events: [%{event: :click, action: :poke}]))
  end

  test "directly owning a dynamic text slot makes the element addressable" do
    assert Compiler.patch_addressable?(
             element(children: [%{kind: :text, content: compiled_expr()}])
           )
  end

  test "directly owning a non-element dynamic child makes the element addressable" do
    assert Compiler.patch_addressable?(element(children: [%{kind: :each, source: :rows}]))
  end

  test "a dynamic grandchild does NOT make the element addressable" do
    dynamic_child = element(children: [%{kind: :text, content: compiled_expr()}])
    refute Compiler.patch_addressable?(element(children: [dynamic_child]))
  end
end
