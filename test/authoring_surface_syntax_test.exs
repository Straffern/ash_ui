defmodule AshUi.AuthoringSurfaceSyntaxTest do
  use ExUnit.Case, async: false
  import AshUi.Expr
  import AshUi.ViewConstructor, except: [item: 1, item: 2, item: 3]
  alias AshUi.EventBinding

  defp unique_module(parts) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    Module.concat([__MODULE__ | parts] ++ [suffix])
  end

  defp explicit_session_contract do
    """
      attributes do
        attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      end

      identities do
        identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
      end
    """
  end

  defp constructor_node(compiled), do: AshUi.ViewConstructor.lower(compiled)

  defmodule ReadAdapter do
    def run_read(_records, _read_name, params, _opts) do
      {:ok, params}
    end
  end

  defmodule InputPage do
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    attributes do
      attribute(:mailbox_id, :string, public?: true)
      attribute(:conversation_id, :string, public?: true)
    end

    actions do
      create :mount do
        change(set_attribute(:mailbox_id, context(:mailbox_id)))
        change(set_attribute(:conversation_id, context(:conversation_id)))
      end
    end

    calculations do
      calculate(:mailbox_id_export, :string, expr(mailbox_id), public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(box(:root, [], [paragraph(:mailbox_label, [], [text("Mailbox")]), text(mailbox_id)]))
      )
    end
  end

  test "typed attrs, bare actions, each constructors, and inline text lower to render nodes" do
    assert %{
             attrs: %{
               "id" => "search-box",
               "spellcheck" => false,
               "autofocus" => true,
               "min" => 1,
               "max" => 10,
               "step" => 2,
               "accept" => ".pdf",
               "data-ash-ui-debounce" => 75
             }
           } =
             AshUi.ViewConstructor.el(
               :input,
               :search,
               [
                 dom_id: "search-box",
                 spellcheck: false,
                 autofocus: true,
                 min: 1,
                 max: 10,
                 step: 2,
                 accept: ".pdf",
                 debounce: 75
               ],
               []
             )

    rows_node =
      constructor_node(
        expr(
          each(entries, :entry, [key: entry.id], [
            paragraph(:entry_label, [], [text(entry.label)])
          ])
        )
      )

    assert %{
             kind: :each,
             as: :entry,
             key: %AshUi.Expr.Compiled{ir: {:_item, :entry, [:id]}}
           } = rows_node

    assert %{
             events: [
               %EventBinding{
                 dom_event: :keydown,
                 ui_event: :save,
                 args_exprs: %{id: %AshUi.Expr.Compiled{ir: {:_dom, :id}}},
                 meta: %{key_filter: %{key: :enter, modifiers: [:meta]}}
               }
             ]
           } =
             AshUi.ViewConstructor.el(
               :button,
               :save,
               [
                 on_keydown: :save,
                 action_input: %{id: {:_dom, :id}},
                 when: AshUi.ViewConstructor.key(:enter, modifiers: [:meta])
               ],
               []
             )
  end

  test "key filters apply only to keyboard bindings on multi-event controls" do
    assert %{events: events} =
             AshUi.ViewConstructor.input(
               :message,
               [
                 name: "message",
                 on_input: :update_message,
                 on_keydown: :submit_message,
                 when: AshUi.ViewConstructor.key(:enter)
               ],
               []
             )

    assert %EventBinding{meta: input_meta} =
             Enum.find(events, &(&1.dom_event == :input))

    assert %EventBinding{meta: keydown_meta} =
             Enum.find(events, &(&1.dom_event == :keydown))

    refute Map.has_key?(input_meta, :key_filter)
    assert keydown_meta.key_filter == %{key: :enter, modifiers: []}
  end

  test "authored attrs option is a compile error" do
    module = unique_module([LegacyAttrsPage])
    source = "defmodule #{inspect(module)} do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

  ets do
    private?(true)
  end

  ash_ui do
  end

#{explicit_session_contract()}

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(button(:legacy, [attrs: %{\"data-legacy\" => \"ok\"}], [text(\"legacy\")])))
  end
end
"

    assert_raise Spark.Error.DslError, ~r"`attrs:` on button is not supported", fn ->
      Code.compile_string(source)
    end
  end

  test "mount state initialization is an ordinary Ash action change" do
    module = unique_module([StrictPage])
    source = "defmodule #{inspect(module)} do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

  ets do
    private?(true)
  end

#{explicit_session_contract()}

  attributes do
    attribute(:mailbox_id, :string, public?: true)
  end

  actions do
    create :mount do
      change set_attribute(:mailbox_id, context(:mailbox_id))
    end
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text(mailbox_id)))
  end
end
"
    Code.compile_string(source)
    resource = AshUi.compile!(module)
    assert Enum.any?(resource.attributes, &(&1.name == :mailbox_id))

    record =
      module
      |> Ash.Changeset.for_create(:mount, %{},
        context: %{mailbox_id: "mailbox-from-context", session_id: "session-1"},
        domain: AshUi.AshDomainFallback
      )
      |> Ash.create!()

    assert record.mailbox_id == "mailbox-from-context"
  end

  test "deleted initial authoring is rejected" do
    module = unique_module([DeletedInitialPage])

    source = "defmodule #{inspect(module)} do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

  ets do
    private?(true)
  end

  ash_ui do
    initial(:mailbox_id, expr(context(:mailbox_id)))
  end

#{explicit_session_contract()}

  attributes do
    attribute(:mailbox_id, :string, public?: true)
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text(mailbox_id)))
  end
end
"

    assert_raise ArgumentError, ~r/unsupported ash_ui config entry: initial/, fn ->
      Code.compile_string(source)
    end
  end

  test "unknown source/state accessors are rejected after source lowering" do
    module = unique_module([StrictUnknownSourcePage])
    source = "defmodule #{inspect(module)} do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

  ets do
    private?(true)
  end

  ash_ui do
  end

#{explicit_session_contract()}

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text(missing)))
  end
end
"

    assert_raise Spark.Error.DslError,
                 ~r"references unknown state :missing",
                 fn -> Code.compile_string(source) end
  end

  test "aria_label on button helpers emits aria-label (H1 regression)" do
    module = unique_module([AriaLabelPage])
    source = "defmodule #{inspect(module)} do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

  ets do
    private?(true)
  end

  ash_ui do
  end

#{explicit_session_contract()}

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(button(:collapse, [aria_label: \"Collapse row\"], [text(\"x\")])))
  end
end
"
    Code.compile_string(source)
    blueprint = Spark.Dsl.Extension.get_persisted(module, :ash_ui_compiled_resource)
    assert inspect(blueprint.view) =~ "aria-label"
    assert inspect(blueprint.view) =~ "Collapse row"
  end

  test "text-inline arities: named node with expr content + opts, and expr + opts (M2)" do
    module = unique_module([InlineArityPage])
    source = "defmodule #{inspect(module)} do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

  ets do
    private?(true)
  end

  ash_ui do
  end

  attributes do
    attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
    attribute :label, :string, default: \"hi\", public?: true
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(box([inline(:field_label, label, [title: \"Field label\"], []), small(label, [title: \"Muted\"], [])])))
  end
end
"
    assert [{_compiled, _} | _] = Code.compile_string(source)
  end

  test "dispatch event bindings do not warn as legacy (H2 scope)" do
    module = unique_module([BareAtomPage])
    source = "defmodule #{inspect(module)} do
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets, extensions: [AshUi]

  ets do
    private?(true)
  end

  ash_ui do
  end

#{explicit_session_contract()}

  actions do
    action :ping, :map do
      run fn _input, _context -> {:ok, %{}} end
    end
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(button(:ping_button, [on_click: :ping], [text(\"ping\")])))
  end
end
"
    warnings = ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(source) end)
    refute warnings =~ "DSL v3 deletes"
  end
end
