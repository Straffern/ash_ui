defmodule AshUi.RenderNodeProtocolTest do
  use ExUnit.Case, async: false
  import AshUi.Expr
  import AshUi.ViewConstructor, except: [item: 1, item: 2, item: 3]
  alias AshUi.EventBinding
  alias AshUi.Runtime.Rendering
  alias AshUi.Runtime.ResourceInfo

  defp unique_module(parts) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    Module.concat([__MODULE__ | parts] ++ [suffix])
  end

  defp constructor_node(compiled), do: AshUi.ViewConstructor.lower(compiled)

  defmodule SourceMapPage do
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
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    attributes do
      attribute(:document_id, :string, public?: true)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text("source-map")))
    end
  end

  defmodule ProtocolPage do
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
      attribute(:selected_job_udi, :string, public?: true)
      attribute(:focused_job_udi, :string, public?: true)
      attribute(:driver_value, :string, default: "session-1", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      update(:select_job) do
        argument(:job_udi, :string, allow_nil?: false)
        change(set_attribute(:selected_job_udi, arg(:job_udi)))
      end

      action(:progress_keydown, :map) do
        argument(:key, :string)
        argument(:job_udi, :string)
        argument(:previous_job_udi, :string)
        argument(:next_job_udi, :string)
        run(fn _input, _context -> {:ok, %{}} end)
      end

      action(:open_context_menu, :map) do
        argument(:job_udi, :string)
        run(fn _input, _context -> {:ok, %{}} end)
      end

      action(:client_selected, :map) do
        run(fn _input, _context -> {:ok, %{}} end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(
            :root,
            [
              client_driver: [
                name: :agent,
                data: [session: driver_value],
                emits: [:client_selected]
              ]
            ],
            [text("driver")]
          )
        )
      )
    end
  end

  test "refs inside compiled map literals resolve at evaluation time" do
    record =
      Ash.Seed.seed!(SourceMapPage, %{
        session_id: Ash.UUID.generate(),
        document_id: "doc-1"
      })

    compiled =
      AshUi.ExprCompiler.compile!(
        expr(%{document_id: document_id, nested: %{id: document_id}})
      )

    assert {:ok, %{document_id: "doc-1", nested: %{id: "doc-1"}}} =
             AshUi.Expr.Eval.eval(
               compiled,
               AshUi.Expr.Scope.new(record, %{}, ash_resource_module: SourceMapPage)
             )
  end

  test "component dynamic map prop registry is empty once component sections are absent" do
    assert [] = AshUi.Info.dynamic_map_props(ProtocolPage)
  end

  test "client_driver emits namespaced data attrs, client actions, and a driver register" do
    record =
      Ash.Seed.seed!(ProtocolPage, %{
        session_id: Ash.UUID.generate(),
        driver_value: "session-9"
      })

    assert {:ok, tree} =
             Rendering.render_tree(ResourceInfo.compiled_resource(ProtocolPage), record, %{})

    root = tree
    assert root.attrs["data-ash-ui-client-driver"] == "agent"
    assert root.attrs["data-agent-session"] == "session-9"
    assert root.attrs["data-ash-ui-client-hook"] == "AshUiClient"
    assert root.attrs["data-ash-ui-client-actions"] =~ "client-selected"
    assert AshUi.Info.client_drivers(ProtocolPage) == [:agent]
  end

  test "client_driver island declarations keep owned fields and client payload sources explicit" do
    node =
      AshUi.ViewConstructor.el(
        :textarea,
        :composer,
        [
          dom_id: "composer-editor",
          client_driver: [
            name: :composer,
            owns: [:value],
            emits: [:client_selected],
            payload_sources: [:textarea_value, :client_read_files]
          ]
        ],
        []
      )

    assert node.attrs["id"] == "composer-editor"
    assert node.attrs["data-ash-ui-client-driver"] == "composer"
    assert node.attrs["data-ash-ui-client-hook"] == "AshUiClient"
    assert node.attrs["data-ash-ui-client-actions"] =~ "client-selected"

    assert [
             [
               name: :composer,
               owns: [:value],
               emits: [:client_selected],
               payload_sources: [:textarea_value, :client_read_files]
             ]
           ] = node.meta.client_driver_contracts
  end

  test "client_driver emitted actions must exist on the page" do
    module = unique_module([MissingClientActionPage])
    source = "defmodule #{inspect(module)} do
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

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(box(:root, [client_driver: [name: :agent, emits: [:missing_action]]], [text(\"bad\")])))
  end
end
"

    assert_raise Spark.Error.DslError, ~r"unknown action `:missing_action`", fn ->
      Code.compile_string(source)
    end
  end

  test "emit_attrs merges caller-supplied attributes into a semantic node" do
    node =
      AshUi.ViewConstructor.el(
        :button,
        :anchor,
        [
          type: :button,
          emit_attrs: %{
            "data-role" => "viewer-event-target",
            "data-viewer-event-type" => "open_anchor",
            "data-anchor-id" => "anchor-1",
            "data-selector-protocol" => "pdf-quote-v1",
            "data-page-no" => "3"
          }
        ],
        [AshUi.ViewConstructor.text("Open source")]
      )

    assert node.attrs["data-role"] == "viewer-event-target"
    assert node.attrs["data-viewer-event-type"] == "open_anchor"
    assert node.attrs["data-anchor-id"] == "anchor-1"
    assert node.attrs["data-selector-protocol"] == "pdf-quote-v1"
    assert node.attrs["data-page-no"] == "3"
  end

  test "emit_attrs as a keyword list merges into a semantic node" do
    node =
      AshUi.ViewConstructor.el(
        :div,
        :target,
        [emit_attrs: [{"data-workbench-typeahead-target", "explorer-filter"}]],
        [AshUi.ViewConstructor.text("Filterable")]
      )

    assert node.attrs["data-workbench-typeahead-target"] == "explorer-filter"
  end

  test "native conditional branches lower collection expressions once" do
    node =
      AshUi.ViewConstructor.fragment([
        constructor_node(
          expr(
            if entries == [] do
              inline(:empty_rows, [], [text("No rows")])
            end
          )
        ),
        constructor_node(
          expr(
            if entries != [] do
              each(entries, :entry, [key: entry.id], [
                paragraph(:entry_label, [], [text(entry.label)])
              ])
            end
          )
        )
      ])

    assert %{
             children: [
               %{kind: :if},
               %{kind: :if, then: %{kind: :each}}
             ]
           } = node
  end

  test "nested empty nodes are rejected by the render tree boundary" do
    node =
      AshUi.ViewConstructor.each(
        {:_ref, [], :entries},
        :entry,
        [key: {:_item, :entry, :id}],
        [
          AshUi.ViewConstructor.el(:div, :row, [], [
            %{
              kind: :empty,
              child:
                AshUi.ViewConstructor.fragment([AshUi.ViewConstructor.text("bad")])
            }
          ])
        ]
      )

    assert {:error, message: message} =
             Ash.Type.apply_constraints(AshUi.Type.RenderTree, node, [])

    assert message =~ "invalid render tree"
    assert message =~ "unknown node kind :empty"
  end

  test "a bare action and action_input lower to one EventBinding" do
    assert %{
             events: [
               %EventBinding{
                 dom_event: :click,
                 ui_event: :open_pdf,
                 args_exprs: %{
                   document_id: %AshUi.Expr.Compiled{ir: {:_dom, :document_id}}
                 },
                 meta: %{}
               }
             ]
           } =
             AshUi.ViewConstructor.button(
               [
                 on_click: :open_pdf,
                 action_input: %{document_id: {:_dom, :document_id}}
               ],
               []
             )
  end
end
