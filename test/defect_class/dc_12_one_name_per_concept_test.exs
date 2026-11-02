defmodule AshUi.DefectClass.OneNamePerConceptTest do
  use ExUnit.Case, async: false

  defp unique_module(parts) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    Module.concat([__MODULE__ | parts] ++ [suffix])
  end

  defp page_source(module, _dsl_version, body) do
    "defmodule #{inspect(module)} do
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
    attribute :name, :string, public?: true, default: \"name\"
    attribute :open?, :boolean, public?: true, default: true
    attribute :data, :map, public?: true, default: %{name: \"nested\"}
    attribute :items, {:array, :map}, public?: true, default: []
    attribute :sort_by, :string, public?: true, default: \"-updated_at\"
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  actions do
    action :save, :map do
      argument :id, :string
      run fn _input, _context -> {:ok, %{}} end
    end
  end

  ash_ui do
  end

  #{body}
end
"
  end

  defp compile_case!(case_def, dsl_version) do
    module = unique_module([case_def.name, :"V#{dsl_version}"])
    source = page_source(module, dsl_version, case_def.body)
    Code.compile_string(source)
  end

  @deleted_cases [
    %{
      name: :inputs_section,
      form: "inputs",
      replacement: "sources do",
      body:
        "inputs do\n  input :mailbox_id, :string, sources: [context: :mailbox_id]\nend\n\nview " <>
          "do\n  text(\"ok\")\nend\n"
    },
    %{
      name: :route_state_section,
      form: "route_state",
      replacement: "route query/param state:",
      body:
        "route_state do\n  state :sort_by, :string, query: :sort_by, default: \"-updated_at\"\nend\n\nview " <>
          "do\n  text(\"ok\")\nend\n"
    },
    %{
      name: :use_template,
      form: "use_template",
      replacement: "render",
      body:
        "components do\n  component :card do\n    view " <>
          "do\n      text(\"card\")\n    end\n  end\nend\n\nview " <>
          "do\n  use_template :card\nend\n"
    },
    %{
      name: :fill_slot,
      form: "fill_slot",
      replacement: "fill",
      body:
        "components do\n  component :panel do\n    slots do\n      slot :body\n    end\n\n    view " <>
          "do\n      yield :body\n    end\n  end\nend\n\nview " <>
          "do\n  render :panel do\n    fill_slot :body do\n      text(\"filled\")\n    end\n  end\nend\n"
    },
    %{
      name: :show_if,
      form: "show_if",
      replacement: "show",
      body: "view " <> "do\n  show_if expr(state(:open?)) do\n    text(\"visible\")\n  end\nend\n"
    },
    %{
      name: :each,
      form: "each",
      replacement: "for_each",
      body:
        "view " <>
          "do\n  each expr(state(:items)), :item, key: expr(item(:item, :name)) do\n    text(expr(item(:item, :name)))\n  end\nend\n"
    },
    %{
      name: :place,
      form: "place",
      replacement: "render(Module, input)",
      body: "view " <> "do\n  place :detail\nend\n"
    },
    %{
      name: :fragment,
      form: "fragment",
      replacement: "box / inline",
      body: "view " <> "do\n  fragment do\n    text(\"fragment\")\n  end\nend\n"
    },
    %{
      name: :group,
      form: "group",
      replacement: "box / inline",
      body: "view " <> "do\n  group do\n    text(\"group\")\n  end\nend\n"
    },
    %{
      name: :stack,
      form: "stack",
      replacement: "box / inline",
      body: "view " <> "do\n  stack do\n    text(\"stack\")\n  end\nend\n"
    },
    %{
      name: :layout_row,
      form: "row",
      replacement: "box / inline",
      body: "view " <> "do\n  row do\n    text(\"row\")\n  end\nend\n"
    },
    %{
      name: :state_mark_alias,
      form: "state",
      replacement: "mark",
      body:
        "view " <> "do\n  box do\n    state :selected, when: expr(state(:open?))\n  end\nend\n"
    },
    %{
      name: :event_binding,
      form: "event_binding",
      replacement: "dispatch/payload/key",
      body:
        "view " <>
          "do\n  button :save, events: [event_binding(:click, :save)] do\n    text(\"save\")\n  end\nend\n"
    },
    %{
      name: :event_tuple,
      form: "event_tuple",
      replacement: "dispatch/payload/key",
      body:
        "view " <>
          "do\n  button :save, events: [click: {:save, %{id: payload(:id)}}] do\n    text(\"save\")\n  end\nend\n"
    },
    %{
      name: :dispatch_by,
      form: "dispatch_by",
      replacement: "dispatch/payload/key",
      body:
        "view " <>
          "do\n  button :save,\n    events: [\n      click:\n        {:dispatch_by, \"intent\", %{\"save\" => :save}, default: :save}\n    ] do\n    text(\"save\")\n  end\nend\n"
    },
    %{
      name: :class_stack,
      form: "class_stack",
      replacement: "mark ... when:",
      body:
        "view " <>
          "do\n  button :save, class: class_stack([\"base\", {expr(state(:open?)), \"open\"}]) do\n    text(\"save\")\n  end\nend\n"
    },
    %{
      name: :class_when,
      form: "class_when",
      replacement: "mark ... when:",
      body:
        "view " <>
          "do\n  button :save, class: class_when([{expr(state(:open?)), \"open\"}], else: \"closed\") do\n    text(\"save\")\n  end\nend\n"
    },
    %{
      name: :get_path,
      form: "get_path",
      replacement: "path",
      body: "view " <> "do\n  text(expr(get_path(state(:data), [:name])))\nend\n"
    },
    %{
      name: :dom_payload_marker,
      form: "dom",
      replacement: "payload",
      body:
        "view " <>
          "do\n  button :save, on_click: dispatch(:save, id: expr(dom(:id))) do\n    text(\"save\")\n  end\nend\n"
    },
    %{
      name: :field_expr,
      form: "field",
      replacement: "item",
      body:
        "view " <>
          "do\n  for_each item <- expr(state(:items)), key: expr(item(:item, :name)) do\n    text(expr(field(:item, :name)))\n  end\nend\n"
    }
  ]
  for case_def <- @deleted_cases do
    test "#{case_def.name} always raises for deleted surface forms" do
      case_def = unquote(Macro.escape(case_def))

      for dsl_version <- [2, 3] do
        try do
          compile_case!(case_def, dsl_version)
          flunk("expected #{case_def.form} to be rejected")
        rescue
          error in Spark.Error.DslError ->
            assert Exception.message(error) =~ "DSL v3 deletes #{case_def.form}"
            assert Exception.message(error) =~ case_def.replacement

          error in CompileError ->
            assert Exception.message(error) =~ "cannot compile module"
        end
      end
    end
  end

  test "View author macro surface stays deleted" do
    assert [] = AshUi.ViewConstructor.__info__(:macros)
    refute function_exported?(AshUi.ViewConstructor, :__author_macro_names__, 0)
  end
end
