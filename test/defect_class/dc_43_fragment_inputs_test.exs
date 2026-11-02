defmodule AshUi.DefectClass.DC43FragmentInputsTest do
  use ExUnit.Case, async: false

  alias AshUi.EventBinding
  alias AshUi.Patch.Bindings
  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Runtime, as: PatchRuntime

  defmodule FormControl do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, public?: true)
      attribute(:control, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
      attribute(:unused, AshUi.Type.RenderTree, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(section(:field, [], [label(:label, [], [text(label)]), control]))
      )
    end
  end

  defmodule RowHost do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:content, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(item(:row, [], [link(:home, [to: "/"], [text("Home")]), content]))
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

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:name, :string, allow_nil?: false, default: "Ada", public?: true)

      attribute(:items, {:array, :map},
        allow_nil?: false,
        default: [],
        public?: true,
        description: "[opaque] keyed fragment-scope fixture"
      )

      attribute(:unrelated, :string, allow_nil?: false, default: "x", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :choose do
        require_atomic?(false)
        argument(:id, :string, allow_nil?: false)
        change(set_attribute(:name, arg(:id)))
      end

      update :ignore do
        require_atomic?(false)
        change(set_attribute(:unrelated, "ignored"))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:page, [], [
            render(
              AshUi.DefectClass.DC43FragmentInputsTest.FormControl,
              %{
                label: "Name",
                control:
                  button(:name_control, [on_click: :choose, action_input: %{id: name}], [
                    text(name)
                  ]),
                unused: button(:dead_control, [on_click: :ignore], [text("dead")])
              }
            ),
            each(items, :entry, [key: entry.id], [
              render(
                AshUi.DefectClass.DC43FragmentInputsTest.RowHost,
                %{
                  content:
                    button(
                      :item_control,
                      [on_click: :choose, action_input: %{id: entry.id}],
                      [text(entry.label)]
                    )
                }
              )
            ])
          ])
        )
      )
    end
  end

  defmodule Shell do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:content, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(box(:shell_root, [], [content])))
    end
  end

  defmodule NestedPage do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    ash_ui do
      stylesheets(["test/support/assets/dc_43.css"])
    end

    routes do
      route("/")
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:sort_by, :string, allow_nil?: false, default: "name", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, create: :*])

      update :change_sort do
        require_atomic?(false)
        argument(:sort_by, :string, allow_nil?: false)
        change(set_attribute(:sort_by, arg(:sort_by)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          render(AshUi.DefectClass.DC43FragmentInputsTest.Shell, %{
            content: [
              render(AshUi.DefectClass.DC43FragmentInputsTest.RowHost, %{
                content: [
                  select(
                    :sort_select,
                    [on_change: :change_sort, action_input: %{sort_by: event(:value)}],
                    [option(:opt, [value: "name"], [text("name")])]
                  )
                ]
              })
            ]
          })
        )
      )
    end
  end

  defmodule ActionChild do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, public?: true)
      attribute(:actions, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(section(:projected_child, [], [text(label), actions]))
      )
    end
  end

  defmodule ProjectedEventsPage do
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
      attribute(:selected_id, :string, allow_nil?: false, default: "none", public?: true)

      attribute(:rows, {:array, :map},
        allow_nil?: false,
        default: [],
        public?: true,
        description: "[opaque] RenderTree-input event rows"
      )
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :page_action do
        require_atomic?(false)
        argument(:id, :string, allow_nil?: false)
        change(set_attribute(:selected_id, arg(:id)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          each(rows, :row, [key: row.id], [
            render(ActionChild, %{
              label: row.label,
              actions:
                button(
                  :act,
                  [on_click: :page_action, action_input: %{id: row.id}],
                  [text("act")]
                )
            })
          ])
        )
      )
    end
  end

  test "fragment values cross render inputs byte-identically on semantic and skeleton paths" do
    page = seed()
    table = Compiler.table(Page)

    rendered = AshUi.Render.build(page, :all, table: table, target: table.target)

    assert semantic_paint(page) ==
             rendered |> AshUi.Rendered.Materialize.to_iodata() |> IO.iodata_to_binary()

    assert {:ok, calculated} =
             Ash.calculate(page, :view,
               domain: AshUi.AshDomainFallback,
               authorize?: false
             )

    assert html(calculated) == semantic_paint(page)
  end

  test "a caller field read only by a fragment invalidates its owned child region" do
    page = seed()
    table = Compiler.table(Page)
    child = Enum.find(Map.values(table.slots), &(&1.kind == :child and :name in &1.deps))

    assert child

    changed = PatchRuntime.changed_addresses(table, page, %{page | name: "Grace"})

    assert MapSet.member?(changed, child.addr)

    assert Enum.all?(changed, fn addr ->
             addr == child.addr or
               Enum.any?(table.slots, fn {_id, slot} ->
                 slot.addr == addr and Map.get(slot.meta, :owner_addr) == child.addr
               end)
           end)

    assert PatchRuntime.changed_addresses(table, page, %{page | unrelated: "y"}) == MapSet.new()
  end

  test "fragment bindings stay in the caller address space and resolve to the caller action" do
    page = seed()
    table = Compiler.table(Page)

    [{addr, entry}] =
      Enum.filter(table.event_elements, fn {addr, entry} ->
        String.contains?(addr, "/acontrol") and Map.has_key?(entry, :node)
      end)

    key = Compiler.addr_component(addr) <> ".click"
    rendered = semantic_paint(page)

    assert rendered =~ ~s(data-ash-ui-binding="#{key}")
    assert {:ok, binding, {:root}} = Bindings.resolve(page, key, %{})
    assert binding.ui_event == :choose
    assert binding.args_exprs == %{id: "Ada"}
    assert entry.eaches == []
  end

  test "an unplaced fragment is dead markup and its forged binding key is unknown" do
    page = seed()
    table = Compiler.table(Page)

    refute Enum.any?(Map.keys(table.event_elements), &String.contains?(&1, "/aunused"))
    refute semantic_paint(page) =~ "dead"

    child_addr =
      table.slots
      |> Map.values()
      |> Enum.find(&(&1.kind == :child and &1.meta.resource == FormControl))
      |> Map.fetch!(:addr)

    forged = Compiler.addr_component(child_addr <> "/aunused") <> ".click"
    assert Bindings.resolve(page, forged, %{}) == :error
  end

  test "fragments inside each templates carry item-key chains and caller item bindings" do
    page = seed(items: [%{id: "r1", label: "Row one"}, %{id: "r2", label: "Row two"}])
    table = Compiler.table(Page)

    [{addr, %{eaches: [_each]}}] =
      Enum.filter(table.event_elements, fn {addr, entry} ->
        String.contains?(addr, "/acontent") and Map.has_key?(entry, :node)
      end)

    key = EventBinding.key_component("r2") <> "." <> Compiler.addr_component(addr) <> ".click"

    assert semantic_paint(page) =~ ~s(data-ash-ui-binding="#{key}")
    assert {:ok, binding, {:root}} = Bindings.resolve(page, key, %{})
    assert binding.ui_event == :choose
    assert binding.args_exprs == %{id: "r2"}
  end

  test "RenderTree inputs in keyed projected children keep page-owned events entry-scoped" do
    page =
      Ash.Seed.seed!(ProjectedEventsPage, %{
        session_id: Ash.UUID.generate(),
        selected_id: "none",
        rows: [%{id: "r1", label: "one"}, %{id: "r2", label: "two"}]
      })

    table = Compiler.table(ProjectedEventsPage)
    rendered_html = semantic_paint(page)
    r2_component = EventBinding.key_component("r2")

    binding_keys =
      Regex.scan(~r/data-ash-ui-binding="([^"]+)"/, rendered_html, capture: :all_but_first)
      |> List.flatten()

    assert binding_keys != [], rendered_html
    r2_keys = Enum.filter(binding_keys, &String.contains?(&1, r2_component))
    assert r2_keys != [], inspect(binding_keys)
    [binding_key] = r2_keys

    assert String.split(binding_key, ".") |> hd() == r2_component

    assert {:ok, %EventBinding{ui_event: :page_action} = binding, {:root}} =
             Bindings.resolve(page, binding_key, %{})

    assert binding.args_exprs == %{id: "r2"}

    assert {:ok, %ProjectedEventsPage{selected_id: "r2"}} =
             AshUi.Patch.Dispatch.run(
               page,
               {:root},
               binding.ui_event,
               binding.args_exprs,
               actor: nil
             )

    initial = AshUi.Render.build(page, :all, table: table, target: table.target)

    {_initial_diff, prints} =
      AshUi.Diff.render(initial, AshUi.Diff.new_fingerprints())

    changed_page =
      %{page | rows: [%{id: "r1", label: "one"}, %{id: "r2", label: "TWO"}]}

    changed = PatchRuntime.changed_addresses(table, page, changed_page)

    patch =
      changed_page
      |> AshUi.Render.build(changed, table: table, target: table.target)
      |> AshUi.Diff.render(prints)
      |> elem(0)

    encoded = Jason.encode!(patch)

    assert contains_key?(patch, :k)
    assert byte_size(encoded) < 512
    assert encoded =~ "TWO"
    refute encoded =~ "one"
    refute Map.has_key?(patch, :s)
  end

  defp seed(overrides \\ []) do
    attrs =
      %{session_id: Ash.UUID.generate(), name: "Ada", items: [], unrelated: "x"}
      |> Map.merge(Map.new(overrides))

    Ash.Seed.seed!(Page, attrs)
  end

  defp semantic_paint(page) do
    resource = page.__struct__

    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(resource),
        page,
        %{},
        []
      )

    html(tree)
  end

  defp html(tree) do
    {:safe, iodata} =
      AshUi.RenderTarget.Html.render_static(tree, target: AshUi.RenderTarget.Static)

    IO.iodata_to_binary(iodata)
  end

  defp contains_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Enum.any?(Map.values(map), &contains_key?(&1, key))
  end

  defp contains_key?(list, key) when is_list(list),
    do: Enum.any?(list, &contains_key?(&1, key))

  defp contains_key?(_other, _key), do: false

  test "NESTED fragments (fragment inside a component inside a fragment) keep ONE key language" do
    page =
      Ash.Seed.seed!(NestedPage, %{session_id: Ash.UUID.generate()})

    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(NestedPage),
        page,
        %{}
      )

    {:safe, iodata} =
      AshUi.RenderTarget.Html.render_static(tree,
        target: AshUi.RenderTarget.Static
      )

    html = IO.iodata_to_binary(iodata)

    assert [_, key] = Regex.run(~r/data-ash-ui-binding="([^"]+)"/, html),
           "nested fragment select must carry a binding key: #{html}"

    # the rendered key must resolve against the CALLER record — the whole
    # point of the one key language
    assert {:ok, binding, {:root}} =
             AshUi.Patch.Bindings.resolve(page, key, %{
               "_target" => ["sort_by"],
               "sort_by" => "-albums",
               "value" => "-albums"
             })

    assert binding.ui_event == :change_sort

    # and the LIVE path (child-slot input evaluator) must emit the SAME
    # keys — the fragment wrapper's stamped address makes materialization
    # idempotent instead of restamping a fresh space
    table = AshUi.Patch.Compiler.table(NestedPage)

    child_slots = Enum.filter(table.slots, fn {_id, slot} -> slot.kind == :child end)

    assert MapSet.new(child_slots, fn {_id, slot} -> slot.meta.resource end) ==
             MapSet.new([Shell, RowHost])

    {_id, slot} =
      Enum.find(child_slots, fn {_id, slot} -> slot.meta.resource == Shell end)

    scope = AshUi.Expr.Scope.new(page, %{}, ash_resource_module: NestedPage)
    input = AshUi.Patch.Evaluator.eval(slot.eval, scope)

    {:safe, live_iodata} =
      AshUi.RenderTarget.Html.render_static(input[:content],
        target: AshUi.RenderTarget.Static
      )

    live_html = IO.iodata_to_binary(live_iodata)

    assert [_, ^key] =
             Regex.run(
               ~r/data-ash-ui-binding="([^"]+)"/,
               live_html
             ),
           "live-path fragment keys must equal semantic-path keys"

    assert live_html =~
             ~s(<a data-ash-ui-link="patch" data-ash-ui-link-state="push" href="/" part="home">Home</a>)
  end
end
