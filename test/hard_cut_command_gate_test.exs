defmodule AshUi.HardCutCommandGateTest do
  use ExUnit.Case, async: true

  @deleted_modules [
    AshUi.CommandDsl,
    AshUi.Runtime.CommandEngine,
    AshUi.Runtime.Commands,
    AshUi.Runtime.CommandState,
    AshUi.Runtime.DomainCall,
    AshUi.Changes.Append,
    AshUi.Changes.Move,
    AshUi.Changes.PutInListItem,
    AshUi.Changes.RemoveAt,
    AshUi.Changes.SetEvaluatedAttribute,
    AshUi.Changes.SetField,
    AshUi.Changes.SetPathAttribute,
    AshUi.Changes.ToggleField
  ]

  test "the command subsystem and AshUi field-surgery changes are absent" do
    Enum.each(@deleted_modules, fn module ->
      refute Code.ensure_loaded?(module), "expected #{inspect(module)} to be deleted"
    end)

    refute Code.ensure_loaded?(AshUi.RuntimeState)
  end

  test "deleted command authoring macros are not imported by the extension" do
    macros = AshUi.__info__(:macros) |> Keyword.keys()

    Enum.each(
      [
        :call,
        :load,
        :load_at,
        :reset,
        :toggle,
        :append,
        :remove_at,
        :move,
        :put_in_list_item,
        :patch,
        :redirect,
        :runtime_bound?,
        :requires_runtime
      ],
      fn name -> refute name in macros end
    )
  end
end
