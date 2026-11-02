defmodule AshUi.ViewLoadTest do
  use ExUnit.Case, async: true

  import AshUi.ViewConstructor

  alias AshUi.ExprCompiler
  alias AshUi.ViewConstructor

  test "derives nested relationship loads through each bindings" do
    compiled =
      ExprCompiler.compile!(
        each({:_ref, [:artist], :albums}, :album, [], [
          text({:_item, :album, [:name]}),
          each({:_item, :album, [:tracks]}, :track, [], [
            text({:_item, :track, [:duration]})
          ])
        ])
      )

    wrapped = %{compiled | ir: [do: compiled.ir]}

    assert ViewConstructor.load_spec(wrapped) == [
             artist: [albums: [:name, tracks: [:duration]]]
           ]
  end
end
