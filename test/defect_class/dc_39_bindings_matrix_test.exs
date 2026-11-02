defmodule AshUi.DefectClass.DC39BindingsMatrixTest do
  @moduledoc """
  DC-39: event-binding resolution matrix. A live binding key is
  `child-addr… item-key… element-addr . dom-event` (dot-joined; addresses
  encode `/`→`-`, `*`→`x`). `AshUi.Patch.Bindings.resolve/3` walks
  the key against the compiled patch tables with ZERO registration:
  descending into child tables at child addresses, binding items by
  `AshUi.Patch.Keys` identity at each boundaries, checking branch-arm
  reachability via accumulated condition chains, then re-evaluating the
  element's bindings against the CURRENT record.

  Matrix: nesting shapes (top-level / branch arms / each / each-in-each /
  child / each-in-child / child-in-each), composite-pk identity, declared
  index bindings, dispatch-time freshness, malformed-key rejection, and
  params observability.
  """
  use ExUnit.Case, async: false

  alias AshUi.EventBinding
  alias AshUi.Patch.Bindings
  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Keys

  defmodule Row do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:message_id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule BookRow do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:book, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:chapter, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule Group do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:gid, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:items, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*, update: :*])
    end
  end

  defmodule StoreButton do
    @moduledoc false
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
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      create :mount do
        accept([:label])
      end

      update(:activate)
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(button(:store_button, [type: :button, on_click: :activate], [text(label)]))
      )
    end
  end

  defmodule ChildPanel do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:name, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
    end

    actions do
      create :create do
        primary?(true)
        accept([:name, :rows])
      end

      update :panel_pick do
        argument(:cid, :string, allow_nil?: false)
      end

      update :panel_row_pick do
        argument(:id, :string, allow_nil?: false)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:panel_root, [], [
            button(
              :panel_pick_btn,
              [type: :button, on_click: :panel_pick, action_input: %{cid: name}],
              [text("panel")]
            ),
            list(:panel_rows, [], [
              each(rows, :prow, [], [
                item(
                  :panel_row,
                  [on_click: :panel_row_pick, action_input: %{id: prow.message_id}],
                  [text(prow.label)]
                )
              ])
            ]),
            render(StoreButton, %{label: name})
          ])
        )
      )
    end
  end

  defmodule RenderTreeShell do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:content, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    actions do
      create :create do
        primary?(true)
        accept([:content])
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(section(:shell, [], [content])))
    end
  end

  defmodule ChildBadge do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:name, :string, primary_key?: true, allow_nil?: false, public?: true)
    end

    actions do
      create :create do
        primary?(true)
        accept([:name])
      end

      update :badge_pick do
        argument(:tag, :string, allow_nil?: false)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          button(:badge_btn, [type: :button, on_click: :badge_pick, action_input: %{tag: name}], [
            text(name)
          ])
        )
      )
    end
  end

  defmodule MatrixPage do
    @moduledoc false
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
      attribute(:flag, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:selected_id, :string, allow_nil?: false, default: "none", public?: true)
      attribute(:panel_name, :string, allow_nil?: false, default: "panel-a", public?: true)
      attribute(:rows, {:array, Row}, allow_nil?: false, default: [], public?: true)
      attribute(:books, {:array, BookRow}, allow_nil?: false, default: [], public?: true)
      attribute(:groups, {:array, Group}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_one(:store_button, StoreButton,
        source_attribute: :session_id,
        destination_attribute: :session_id,
        public?: true
      )
    end

    actions do
      defaults([:read])

      update :select do
        require_atomic?(false)
        argument(:id, :string, allow_nil?: false)
        change(set_attribute(:selected_id, arg(:id)))
      end

      update :pick_entry do
        require_atomic?(false)
        argument(:gid, :string, allow_nil?: false)
        argument(:id, :string, allow_nil?: false)
        change(set_attribute(:selected_id, arg(:id)))
      end

      update :choose_book do
        require_atomic?(false)
        argument(:book, :string, allow_nil?: false)
        argument(:chapter, :string, allow_nil?: false)
        change(set_attribute(:selected_id, arg(:chapter)))
      end

      update :move do
        require_atomic?(false)
        argument(:at, :integer, allow_nil?: false)
        change(set_attribute(:selected_id, "moved"))
      end

      update :set_label do
        require_atomic?(false)
        argument(:value, :string)
        change(set_attribute(:selected_id, "labeled"))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:dc39_root, [], [
            button(
              :top_pick,
              [type: :button, on_click: :select, action_input: %{id: selected_id}],
              [text("pick")]
            ),
            if flag do
              button(
                :arm_then,
                [type: :button, on_click: :select, action_input: %{id: "then-arm"}],
                [text("t")]
              )
            else
              button(
                :arm_else,
                [type: :button, on_click: :select, action_input: %{id: "else-arm"}],
                [text("f")]
              )
            end,
            list(:row_list, [], [
              each(rows, :row, [], [
                item(:row_item, [on_click: :select, action_input: %{id: row.message_id}], [
                  text(row.label)
                ])
              ])
            ]),
            list(:group_list, [], [
              each(groups, :group, [], [
                item(:group_item, [], [
                  list(:entry_list, [], [
                    each(group.items, :entry, [], [
                      item(
                        :entry_item,
                        [
                          on_click: :pick_entry,
                          action_input: %{gid: group.gid, id: entry.message_id}
                        ],
                        [text(entry.label)]
                      )
                    ])
                  ])
                ])
              ])
            ]),
            list(:book_list, [], [
              each(books, :brow, [], [
                item(
                  :book_item,
                  [
                    on_click: :choose_book,
                    action_input: %{book: brow.book, chapter: brow.chapter}
                  ],
                  [text(brow.label)]
                )
              ])
            ]),
            list(:index_list, [], [
              each(rows, :irow, [index: :ipos], [
                item(:index_item, [on_click: :move, action_input: %{at: index(:ipos)}], [
                  text(irow.label)
                ])
              ])
            ]),
            render(ChildPanel, %{name: panel_name, rows: rows}),
            list(:badge_list, [], [
              each(rows, :crow, [], [
                item(:badge_item, [], [render(ChildBadge, %{name: crow.message_id})])
              ])
            ]),
            render(RenderTreeShell, %{
              content: render(StoreButton, %{label: panel_name})
            }),
            input(
              :label_input,
              type: :text,
              on_input: :set_label,
              action_input: %{value: event(:value)}
            )
          ])
        )
      )
    end
  end

  @default_rows [%{message_id: "m1", label: "one"}, %{message_id: "m2", label: "two"}]

  defp seed(attrs \\ %{}) do
    Ash.Seed.seed!(
      MatrixPage,
      Map.merge(
        %{
          session_id: Ash.UUID.generate(),
          rows: rows(@default_rows)
        },
        Map.new(attrs)
      )
    )
  end

  defp rows(list), do: Enum.map(list, &struct(Row, &1))

  defp table, do: Compiler.table(MatrixPage)

  defp addr_component(table, part) do
    table.event_elements
    |> Enum.find(fn {_addr, entry} ->
      case Map.get(entry, :node) do
        %{part: ^part} -> true
        _other -> false
      end
    end)
    |> case do
      {addr, _entry} ->
        Compiler.addr_component(addr)

      nil ->
        flunk(
          "no event element with part #{inspect(part)}; " <>
            "have: #{inspect(Enum.map(table.event_elements, fn {_a, e} -> e.node.part end))}"
        )
    end
  end

  defp child_addr_component(table, resource) do
    table.children
    |> Enum.find(fn {_addr, child} -> child.resource == resource end)
    |> case do
      {addr, _child} -> Compiler.addr_component(addr)
      nil -> flunk("no child table for #{inspect(resource)}")
    end
  end

  defp child_table(table, resource) do
    {_addr, child} = Enum.find(table.children, fn {_a, c} -> c.resource == resource end)
    child
  end

  defp key(components), do: Enum.join(components, ".")

  # ── gate 1: resolution across nesting ─────────────────────────────────────

  describe "gate 1: nesting" do
    test "top-level element resolves and evaluates its payload" do
      page = seed(%{selected_id: "none"})
      k = key([addr_component(table(), :top_pick), "click"])

      assert {:ok, %EventBinding{dom_event: :click, ui_event: :select} = binding, {:root}} =
               Bindings.resolve(page, k)

      assert binding.args_exprs[:id] == "none"
    end

    test "branch arms resolve only while their arm is live, both ways" do
      then_key = key([addr_component(table(), :arm_then), "click"])
      else_key = key([addr_component(table(), :arm_else), "click"])

      on_page = seed(%{flag: true})

      assert {:ok, %EventBinding{} = then_binding, {:root}} =
               Bindings.resolve(on_page, then_key)

      assert then_binding.args_exprs[:id] == "then-arm"
      assert :error = Bindings.resolve(on_page, else_key)

      # flip the condition: the previously-live arm goes stale, the other lights up
      off_page = %{on_page | flag: false}
      assert :error = Bindings.resolve(off_page, then_key)

      assert {:ok, %EventBinding{} = else_binding, {:root}} =
               Bindings.resolve(off_page, else_key)

      assert else_binding.args_exprs[:id] == "else-arm"
    end

    test "each element binds by item key; wrong and missing keys are ordinary unknown targets" do
      page = seed()
      row_addr = addr_component(table(), :row_item)

      assert {:ok, %EventBinding{} = binding, {:root}} =
               Bindings.resolve(page, key([EventBinding.key_component("m2"), row_addr, "click"]))

      assert binding.args_exprs[:id] == "m2"

      assert {:ok, %EventBinding{} = binding1, {:root}} =
               Bindings.resolve(page, key([EventBinding.key_component("m1"), row_addr, "click"]))

      assert binding1.args_exprs[:id] == "m1"

      # wrong item key
      assert :error =
               Bindings.resolve(page, key([EventBinding.key_component("zz"), row_addr, "click"]))

      # missing item key while the element sits under an each
      assert :error = Bindings.resolve(page, key([row_addr, "click"]))
    end

    test "each-in-each requires BOTH item keys in outermost-first order" do
      page =
        seed(%{
          groups: [
            struct(Group, %{
              gid: "g1",
              items:
                rows([%{message_id: "m1", label: "g1-m1"}, %{message_id: "m2", label: "g1-m2"}])
            }),
            struct(Group, %{gid: "g2", items: rows([%{message_id: "m1", label: "g2-m1"}])})
          ]
        })

      entry_addr = addr_component(table(), :entry_item)
      g1 = EventBinding.key_component("g1")
      g2 = EventBinding.key_component("g2")
      m1 = EventBinding.key_component("m1")
      m2 = EventBinding.key_component("m2")

      assert {:ok, %EventBinding{} = binding, {:root}} =
               Bindings.resolve(page, key([g1, m2, entry_addr, "click"]))

      assert binding.args_exprs == %{gid: "g1", id: "m2"}

      # both groups contain an "m1": the OUTER key decides which each scope binds
      assert {:ok, %EventBinding{} = g2_binding, {:root}} =
               Bindings.resolve(page, key([g2, m1, entry_addr, "click"]))

      assert g2_binding.args_exprs == %{gid: "g2", id: "m1"}

      # truncated chain: one key for two eaches
      assert :error = Bindings.resolve(page, key([g1, entry_addr, "click"]))

      # inner key that only exists in the OTHER group
      assert :error = Bindings.resolve(page, key([g2, m2, entry_addr, "click"]))

      # keys in the wrong order (inner first) fail item binding
      assert :error = Bindings.resolve(page, key([m1, g1, entry_addr, "click"]))
    end

    test "an embedded child rendered from a projection is not an addressable target" do
      page = seed(%{panel_name: "panel-a"})
      child_addr = child_addr_component(table(), ChildPanel)
      panel_btn = addr_component(child_table(table(), ChildPanel), :panel_pick_btn)

      assert :error = Bindings.resolve(page, key([child_addr, panel_btn, "click"]))
    end

    test "items inside an embedded child projection are not addressable targets" do
      page = seed()
      child_addr = child_addr_component(table(), ChildPanel)
      panel_row = addr_component(child_table(table(), ChildPanel), :panel_row)
      m2 = EventBinding.key_component("m2")

      assert :error = Bindings.resolve(page, key([child_addr, m2, panel_row, "click"]))

      # wrong / missing item key inside the child
      assert :error =
               Bindings.resolve(
                 page,
                 key([child_addr, EventBinding.key_component("zz"), panel_row, "click"])
               )

      assert :error = Bindings.resolve(page, key([child_addr, panel_row, "click"]))
    end

    test "a projected embedded child inside an each is not an addressable target" do
      page = seed()
      badge_addr = child_addr_component(table(), ChildBadge)
      badge_btn = addr_component(child_table(table(), ChildBadge), :badge_btn)
      m1 = EventBinding.key_component("m1")

      assert :error = Bindings.resolve(page, key([m1, badge_addr, badge_btn, "click"]))
    end

    test "a store-backed child nested inside an embedded projection is addressable" do
      page = seed(%{panel_name: "panel-a"})
      panel_addr = child_addr_component(table(), ChildPanel)
      panel_table = child_table(table(), ChildPanel)
      store_addr = child_addr_component(panel_table, StoreButton)
      store_button = addr_component(child_table(panel_table, StoreButton), :store_button)

      assert {:ok, %EventBinding{ui_event: :activate}, {:row, %StoreButton{} = target}} =
               Bindings.resolve(
                 page,
                 key([panel_addr, store_addr, store_button, "click"]),
                 %{},
                 session_id: page.session_id
               )

      assert target.session_id == page.session_id
      assert target.label == "panel-a"
    end

    test "a store-backed child projected through a RenderTree input is addressable" do
      page = seed(%{panel_name: "projected"})
      store_addr = child_addr_component(table(), StoreButton)
      store_table = child_table(table(), StoreButton)
      store_button = addr_component(store_table, :store_button)

      assert {:ok, %EventBinding{ui_event: :activate}, {:row, %StoreButton{} = target}} =
               Bindings.resolve(
                 page,
                 key([store_addr, store_button, "click"]),
                 %{},
                 session_id: page.session_id
               )

      assert target.session_id == page.session_id
      assert target.label == "projected"
    end
  end

  # ── gate 2: composite-pk identity ─────────────────────────────────────────

  describe "gate 2: composite identity" do
    test "entry key is the FULL primary-key tuple" do
      row = struct(BookRow, %{book: "a", chapter: "1", label: "a1"})
      assert Keys.entry_key(row, 0) == {"a", "1"}
    end

    test "two rows sharing the first pk field resolve to distinct correct rows" do
      page =
        seed(%{
          books: [
            struct(BookRow, %{book: "a", chapter: "1", label: "a1"}),
            struct(BookRow, %{book: "a", chapter: "2", label: "a2"})
          ]
        })

      book_addr = addr_component(table(), :book_item)
      key_a1 = EventBinding.key_component({"a", "1"})
      key_a2 = EventBinding.key_component({"a", "2"})
      refute key_a1 == key_a2

      assert {:ok, %EventBinding{} = binding1, {:root}} =
               Bindings.resolve(page, key([key_a1, book_addr, "click"]))

      assert binding1.args_exprs == %{book: "a", chapter: "1"}

      assert {:ok, %EventBinding{} = binding2, {:root}} =
               Bindings.resolve(page, key([key_a2, book_addr, "click"]))

      assert binding2.args_exprs == %{book: "a", chapter: "2"}

      # first-field-only keying must NOT match a composite identity
      assert :error =
               Bindings.resolve(page, key([EventBinding.key_component("a"), book_addr, "click"]))
    end
  end

  # ── gate 3: declared index ────────────────────────────────────────────────

  describe "gate 3: declared index" do
    test "payload carries the row's CURRENT ordinal position, not its pk" do
      page = seed()
      index_addr = addr_component(table(), :index_item)
      m2 = EventBinding.key_component("m2")

      assert {:ok, %EventBinding{} = binding, {:root}} =
               Bindings.resolve(page, key([m2, index_addr, "click"]))

      assert binding.args_exprs == %{at: 1}

      # reorder the rows: the SAME key now reports the new ordinal
      reordered = %{page | rows: Enum.reverse(page.rows)}

      assert {:ok, %EventBinding{} = rebinding, {:root}} =
               Bindings.resolve(reordered, key([m2, index_addr, "click"]))

      assert rebinding.args_exprs == %{at: 0}
    end
  end

  # ── gate 4: dispatch-time freshness ───────────────────────────────────────

  describe "gate 4: dispatch-time freshness" do
    test "payload expressions re-evaluate against the record passed to each resolve" do
      page = seed(%{selected_id: "none"})
      k = key([addr_component(table(), :top_pick), "click"])

      assert {:ok, %EventBinding{} = before_binding, {:root}} = Bindings.resolve(page, k)
      assert before_binding.args_exprs[:id] == "none"

      updated =
        page
        |> Ash.Changeset.for_update(:select, %{id: "m1"},
          domain: AshUi.AshDomainFallback,
          authorize?: false
        )
        |> Ash.update!(domain: AshUi.AshDomainFallback)

      assert {:ok, %EventBinding{} = after_binding, {:root}} = Bindings.resolve(updated, k)
      assert after_binding.args_exprs[:id] == "m1"
    end

    test "freshness does not make a child projection addressable" do
      page = seed(%{panel_name: "panel-a"})
      child_addr = child_addr_component(table(), ChildPanel)
      panel_btn = addr_component(child_table(table(), ChildPanel), :panel_pick_btn)
      k = key([child_addr, panel_btn, "click"])

      assert :error = Bindings.resolve(page, k)

      renamed = %{page | panel_name: "panel-b"}
      assert :error = Bindings.resolve(renamed, k)
    end
  end

  # ── gate 5: malformed keys ────────────────────────────────────────────────

  describe "gate 5: malformed keys" do
    test "degenerate keys are :error, never a raise" do
      page = seed()

      assert :error = Bindings.resolve(page, "")
      assert :error = Bindings.resolve(page, ".")
      assert :error = Bindings.resolve(page, "...")
      # event-only / single-component keys
      assert :error = Bindings.resolve(page, "click")
      assert :error = Bindings.resolve(page, addr_component(table(), :top_pick))
    end

    test "truncated and over-long chains are :error" do
      page =
        seed(%{
          groups: [struct(Group, %{gid: "g1", items: rows([%{message_id: "m1", label: "x"}])})]
        })

      row_addr = addr_component(table(), :row_item)
      top_addr = addr_component(table(), :top_pick)
      entry_addr = addr_component(table(), :entry_item)
      m1 = EventBinding.key_component("m1")
      m2 = EventBinding.key_component("m2")
      g1 = EventBinding.key_component("g1")

      # missing item key when the element sits under eaches
      assert :error = Bindings.resolve(page, key([row_addr, "click"]))
      assert :error = Bindings.resolve(page, key([entry_addr, "click"]))
      assert :error = Bindings.resolve(page, key([g1, entry_addr, "click"]))

      # extra keys when none (or fewer) are expected
      assert :error = Bindings.resolve(page, key([m1, top_addr, "click"]))
      assert :error = Bindings.resolve(page, key([m1, m2, row_addr, "click"]))
      assert :error = Bindings.resolve(page, key([g1, m1, m2, entry_addr, "click"]))
    end

    test "nonexistent addresses and events are :error" do
      page = seed()
      top_addr = addr_component(table(), :top_pick)
      child_addr = child_addr_component(table(), ChildPanel)

      assert :error = Bindings.resolve(page, "zzz.click")
      assert :error = Bindings.resolve(page, "v-9-9.click")
      assert :error = Bindings.resolve(page, key([child_addr, "v-9-9", "click"]))
      # real element, wrong dom event
      assert :error = Bindings.resolve(page, key([top_addr, "mouseover"]))
      # real element used as a CHILD boundary
      assert :error = Bindings.resolve(page, key([top_addr, top_addr, "click"]))
    end

    test "item identities serialize injectively from compiled addresses" do
      top_addr = addr_component(table(), :top_pick)
      row_addr = addr_component(table(), :row_item)

      # a row whose pk IS the encoded address of a real event element
      page = seed(%{rows: rows([%{message_id: top_addr, label: "trap"}])})
      refute EventBinding.key_component(top_addr) == top_addr

      assert {:ok, binding, {:root}} =
               Bindings.resolve(
                 page,
                 key([EventBinding.key_component(top_addr), row_addr, "click"])
               )

      assert binding.args_exprs[:id] == top_addr

      # ... and a row keyed by the element's OWN address remains distinct.
      page2 = seed(%{rows: rows([%{message_id: row_addr, label: "trap2"}])})

      assert {:ok, binding2, {:root}} =
               Bindings.resolve(
                 page2,
                 key([EventBinding.key_component(row_addr), row_addr, "click"])
               )

      assert binding2.args_exprs[:id] == row_addr

      refute EventBinding.key_component("a.") == EventBinding.key_component("bYS4")
      refute EventBinding.key_component("1") == EventBinding.key_component(1)
    end
  end

  # ── gate 6: params ────────────────────────────────────────────────────────

  describe "gate 6: params" do
    # resolve/3's params map lands in scope.args, but the authoring surface
    # REJECTS bare `arg(...)` refs in resource views (surface_contracts.ex:
    # `{:arg, name}` requires `template_scope_local?`, and locals are only
    # populated for each-item bindings via put_template_scope_item/2), so no
    # legally-authored payload expression can observe resolve/3 params
    # directly. DOM-event params reach payloads exclusively through
    # `event(:field)` markers, which resolution preserves UNevaluated and
    # `EventBinding.runtime_event/2` substitutes at dispatch time.
    test "event(:field) payload markers survive resolution and substitute at dispatch" do
      page = seed()
      input_addr = addr_component(table(), :label_input)
      k = key([input_addr, "input"])

      assert {:ok, %EventBinding{dom_event: :input, ui_event: :set_label} = binding, {:root}} =
               Bindings.resolve(page, k)

      assert binding.args_exprs[:value] == {:event, :value}

      assert {:dispatch, _path, :set_label, payload} =
               EventBinding.runtime_event(binding, %{"value" => "hello"})

      assert payload[:value] == "hello"
    end

    test "resolve/3 accepts a params map without changing record-derived payloads" do
      page = seed(%{selected_id: "none"})
      k = key([addr_component(table(), :top_pick), "click"])

      assert {:ok, %EventBinding{} = bare, {:root}} = Bindings.resolve(page, k)

      assert {:ok, %EventBinding{} = with_params, {:root}} =
               Bindings.resolve(page, k, %{"id" => "spoof"})

      # record-derived payloads come from the record, not the params map
      assert bare.args_exprs == with_params.args_exprs
      assert with_params.args_exprs[:id] == "none"

      assert {:dispatch, _path, :select, payload} =
               EventBinding.runtime_event(with_params, %{"id" => "spoof"})

      assert payload[:id] == "none"
      assert payload["id"] == "spoof"
    end
  end

  # DC-39 addendum (explorer cutover finding): the renderer's each-chain
  # key must honor the authored key: exactly as the resolver does — a
  # keyless embedded row with key: row.label must round-trip through the
  # REAL rendered binding key.
  defmodule KeylessRow do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule AuthoredKeyPage do
    @moduledoc false
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
      attribute(:picked, :string, allow_nil?: false, default: "none", public?: true)
      attribute(:krows, {:array, KeylessRow}, allow_nil?: false, default: [], public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      create :mount do
      end

      update :pick do
        require_atomic?(false)
        argument(:id, :string, allow_nil?: false)
        change(set_attribute(:picked, arg(:id)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          list(:krows, [], [
            each(krows, :krow, [key: krow.label], [
              item(:kentry, [on_click: :pick, action_input: %{id: krow.label}], [
                text(krow.label)
              ])
            ])
          ])
        )
      )
    end
  end

  test "authored key: renders the SAME chain key the resolver accepts (keyless embedded)" do
    page =
      Ash.Seed.seed!(AuthoredKeyPage, %{
        session_id: Ash.UUID.generate(),
        krows: [struct(KeylessRow, %{label: "alpha"}), struct(KeylessRow, %{label: "beta"})]
      })

    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(AuthoredKeyPage),
        page,
        %{},
        []
      )

    {:safe, iodata} =
      AshUi.RenderTarget.Html.render_static(tree)

    html = IO.iodata_to_binary(iodata)

    prefix = Regex.escape(EventBinding.key_component("beta"))
    [_, key] = Regex.run(~r/binding="(#{prefix}[^"]+)"/, html)

    assert {:ok, binding, {:root}} = Bindings.resolve(page, key)
    assert inspect(binding.args_exprs) =~ "beta"
  end
end
