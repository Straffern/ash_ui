defmodule AshUi.IfElseHintVerifierTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  defp unique_module(name) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    Module.concat([__MODULE__, name, suffix])
  end

  test "complementary sibling if blocks emit an if/else hint" do
    page = unique_module(ComplementaryIfPage)
    source = "defmodule #{inspect(page)} do
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
    attribute :open?, :boolean, default: false
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(box(:root, [], [
  if open? do
    text(\"Open\")
  else
    nothing()
  end,
  if not open? do
    text(\"Closed\")
  else
    nothing()
  end
])))
  end
end
"
    warnings = capture_io(:stderr, fn -> Code.compile_string(source) end)
    assert warnings =~ "if/else"
    assert warnings =~ "complementary sibling if blocks"
  end

  test "non-complementary sibling if blocks do not emit the hint" do
    page = unique_module(NonComplementaryIfPage)
    source = "defmodule #{inspect(page)} do
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
    attribute :open?, :boolean, default: false
    attribute :selected?, :boolean, default: false
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(box(:root, [], [
  if open? do
    text(\"Open\")
  else
    nothing()
  end,
  if selected? do
    text(\"Selected\")
  else
    nothing()
  end
])))
  end
end
"
    warnings = capture_io(:stderr, fn -> Code.compile_string(source) end)
    refute warnings =~ "if/else"
    refute warnings =~ "complementary sibling if blocks"
  end
end
