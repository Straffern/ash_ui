defmodule AshUi.DefectClass.DC22ExportsAsCalculationsTest do
  @moduledoc """
  DC-22: exports were the second model's cross-surface value channel
  (export calculations resolved through the Runtime facade and Adapter).
  Exports are deleted wholesale with that model; ordinary Ash calculations
  on the page resource are the only derived-value surface. This gate
  verifies the export machinery stays deleted.
  """
  use ExUnit.Case, async: true

  test "the exports machinery is absent" do
    for module <- [
          AshUi.ExportCalculation,
          AshUi.Runtime.Exports,
          AshUi.Runtime,
          AshUi.Adapter
        ] do
      refute Code.ensure_loaded?(module), "expected #{inspect(module)} to be deleted"
    end
  end

  test "the extension DSL no longer exposes export authoring" do
    refute :export in Keyword.keys(AshUi.__info__(:macros))

    sections = AshUi.sections()

    refute Enum.any?(sections, fn section -> section.name == :exports end),
           "expected no :exports DSL section"
  end
end
