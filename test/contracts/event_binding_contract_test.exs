defmodule AshUi.Contracts.EventBindingContractTest do
  use ExUnit.Case, async: false
  import AshUi.ViewConstructor
  alias AshUi.EventBinding
  alias AshUi.RenderTree

  test "keeps Decimal values in authored action input" do
    binding =
      EventBinding.new(:submit, :save, args_exprs: %{baseline_value: Decimal.new("0")})

    assert {:dispatch, [], :save, %{baseline_value: value}} =
             EventBinding.runtime_event(binding, %{})

    assert value == Decimal.new("0")
  end

  test "keeps embedded structs in authored action input" do
    subject = %URI{scheme: "urn", path: "okr:objective"}

    binding =
      EventBinding.new(:submit, :save, args_exprs: %{subject: subject})

    assert {:dispatch, [], :save, %{subject: ^subject}} =
             EventBinding.runtime_event(binding, %{})
  end

  test "keeps structs in ordinary dispatch action input" do
    subject = %URI{scheme: "urn", path: "track:one"}

    binding =
      EventBinding.new(:submit, :save, args_exprs: %{subjects: [subject]})

    assert {:dispatch, [], :save, %{subjects: [^subject]}} =
             EventBinding.runtime_event(binding, %{})
  end

  test "preserves form fields named intent inside ordinary event params" do
    binding = EventBinding.new(:submit, :submit)

    assert {:dispatch, [], :submit, payload} =
             EventBinding.runtime_event(binding, %{
               "intent" => "okr_test_run",
               "subject" => ~s({"objective_id":"objective-1"})
             })

    assert payload["intent"] == "okr_test_run"
    assert payload["subject"] == ~s({"objective_id":"objective-1"})
  end

  test "runtime params cannot override authored atom-key binding arguments" do
    binding =
      EventBinding.new(:click, :active_ref_changed,
        args_exprs: %{active_ref_uri: "", dirty?: false}
      )

    assert {:dispatch, [], :active_ref_changed,
            %{
              :active_ref_uri => "",
              :dirty? => false,
              "active_ref_uri" => "/docs/example.md",
              "dirty?" => true
            }} =
             EventBinding.runtime_event(binding, %{
               "active_ref_uri" => "/docs/example.md",
               "dirty?" => true
             })
  end

  test "provided-value bindings replace nil static value with targeted DOM payload" do
    binding =
      EventBinding.new(:input, :set_query,
        args_exprs: %{value: nil},
        meta: %{provides_value?: true}
      )

    assert {:dispatch, [], :set_query,
            %{"_target" => ["query"], "query" => "wingardium", "value" => "wingardium"}} =
             EventBinding.runtime_event(binding, %{
               "_target" => ["query"],
               "query" => "wingardium"
             })
  end

  test "field-name bindings pass the control value to the matching action input" do
    binding =
      EventBinding.new(:input, :rename, meta: %{provides_value?: true, bound_field: :name})

    assert {:dispatch, [], :rename, %{"value" => "Renamed", name: "Renamed"}} =
             EventBinding.runtime_event(binding, %{"value" => "Renamed"})
  end

  test "event payload schemas expose canonical fields per DOM event type" do
    assert EventBinding.payload_schema(:click) == [:button, :buttons, :alt, :ctrl, :meta, :shift]
    assert EventBinding.payload_field?(:keydown, :key)
    assert EventBinding.payload_field?(:click, :shift)
    refute EventBinding.payload_field?(:click, :shiftKey)
    refute EventBinding.payload_field?(:click, :value)
  end

  test "event payload accessors resolve browser metadata without static DOM value attrs" do
    binding =
      EventBinding.new(:keydown, :move_focus,
        args_exprs: %{key: {:event, :key}, shift: {:event, :shift}}
      )

    assert {:dispatch, [], :move_focus,
            %{:key => "ArrowDown", :shift => true, "key" => "ArrowDown", "shiftKey" => true}} =
             EventBinding.runtime_event(binding, %{"key" => "ArrowDown", "shiftKey" => true})
  end

  test "event-type value extraction maps checkbox and multi-select payloads" do
    checkbox =
      EventBinding.new(:change, :toggle_flag,
        args_exprs: %{value: nil},
        meta: %{
          provides_value?: true,
          value_source: :checked
        }
      )

    assert {:dispatch, [], :toggle_flag, %{"checked" => true, "value" => true}} =
             EventBinding.runtime_event(checkbox, %{"checked" => true})

    multi_select =
      EventBinding.new(:change, :set_tags,
        args_exprs: %{value: nil},
        meta: %{
          provides_value?: true,
          value_source: :selected_options
        }
      )

    assert {:dispatch, [], :set_tags, %{"selectedOptions" => ["a", "b"], "value" => ["a", "b"]}} =
             EventBinding.runtime_event(multi_select, %{"selectedOptions" => ["a", "b"]})
  end

  defmodule Badge do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:id, :string, public?: true)
      attribute(:label, :string, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      update(:rename) do
        argument(:label, :string, allow_nil?: false)
        change(set_attribute(:label, arg(:label)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(
            :badge_root,
            [action_input: %{label: label}, data: [role: "badge"], on_click: :rename],
            [text(label)]
          )
        )
      )
    end
  end

  defmodule TrackButton do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, public?: true)
      attribute(:label, :string, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(box(:track_button_root, [data: [id: id]], [text(label)]))
      )
    end
  end

  defmodule Page do
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

      attribute(:tracks, {:array, :map},
        public?: true,
        description: "[opaque] test fixture — shape immaterial here"
      )
    end

    relationships do
      has_one(:badge, Badge,
        source_attribute: :session_id,
        destination_attribute: :session_id,
        public?: true
      )
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:root, [], [
            each(tracks, :track, [], [render(TrackButton, %{id: track.id, label: track.label})]),
            render(Badge, badge)
          ])
        )
      )
    end
  end

  test "render trees keep semantic event bindings on child records and keyed each children" do
    session_id = Ash.UUID.generate()

    record =
      Page
      |> Ash.Seed.seed!(%{
        session_id: session_id,
        tracks: [%{id: "track-1", label: "First"}, %{id: "track-2", label: "Second"}]
      })
      |> Map.put(:badge, %Badge{session_id: session_id, label: "Nested"})

    assert {:ok, %RenderTree.Element{children: [fragment, badge_view]}} =
             AshUi.Runtime.Rendering.render_tree(
               AshUi.Runtime.ResourceInfo.compiled_resource(Page),
               record,
               %{}
             )

    assert %RenderTree.Fragment{
             children: [
               %RenderTree.Element{attrs: %{"data-id" => "track-1"}},
               %RenderTree.Element{attrs: %{"data-id" => "track-2"}}
             ]
           } = fragment

    assert [%EventBinding{dom_event: :click, ui_event: :rename}] =
             badge_event_bindings(badge_view)
  end

  defp badge_event_bindings(%RenderTree.Element{event_bindings: [_ | _] = bindings}) do
    bindings
  end

  defp badge_event_bindings(%{children: children}) when is_list(children) do
    Enum.flat_map(children, &badge_event_bindings/1)
  end

  defp badge_event_bindings(%{view: view}) do
    badge_event_bindings(view)
  end

  defp badge_event_bindings(_node) do
    []
  end

  defmodule TrackLabels do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:tracks, {:array, :map},
        default: [],
        public?: true,
        description: "[opaque] test fixture — shape immaterial here"
      )
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(each(tracks, :track, [key: track.id], [box(:track_label, [], [text(track.label)])]))
      )
    end
  end

  test "value-resource loops keep keys on explicit item boxes" do
    assert {:ok,
            %RenderTree.Fragment{
              children: [%RenderTree.Element{key: "track-1"}, %RenderTree.Element{key: "track-2"}]
            }} =
             render_value_resource(TrackLabels, %{
               tracks: [%{id: "track-1", label: "First"}, %{id: "track-2", label: "Second"}]
             })
  end

  defp render_value_resource(module, attrs, opts \\ []) do
    with {:ok, record} <-
           AshUi.Runtime.ResourceComponentRender.build_resource_component_record(
             module,
             attrs,
             opts
           ) do
      module
      |> AshUi.Compiled.resource!()
      |> AshUi.Runtime.Rendering.render_tree(
        record,
        %{},
        Keyword.merge([ash_resource_module: module, helper_module: module], opts)
      )
    end
  end
end
