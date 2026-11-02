defmodule AshUi.ReloadContractTest.Row do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    validate_domain_inclusion?: false

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:page_key, :string, allow_nil?: false, public?: true)
    attribute(:body, :string, allow_nil?: false, default: "", public?: true)
  end

  calculations do
    calculate(:body_changed?, :boolean, expr(body == "b"))
  end

  actions do
    defaults([:read, create: :*, update: :*])
  end
end

defmodule AshUi.ReloadContractTest.ManualRows do
  @moduledoc false
  use Ash.Resource.ManualRelationship

  alias AshUi.ReloadContractTest.Row

  @impl true
  def load(records, _opts, _context) do
    rows = Ash.read!(Row, domain: AshUi.AshDomainFallback, authorize?: false)

    {:ok, Map.new(records, fn record -> {Map.take(record, [:session_id]), rows} end)}
  end
end

defmodule AshUi.ReloadContractTest.RowsDigest do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:rows]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      record.rows |> List.wrap() |> Enum.map_join(",", & &1.body)
    end)
  end
end

defmodule AshUi.ReloadContractTest.OpaqueNode do
  @moduledoc false
  defstruct [:id, :label]
end

defmodule AshUi.ReloadContractTest.OpaqueTree do
  @moduledoc false
  defstruct nodes: []
end

defmodule AshUi.ReloadContractTest.OpaqueTreeType do
  @moduledoc false
  use Ash.Type

  alias AshUi.ReloadContractTest.OpaqueTree

  @impl Ash.Type
  def storage_type(_constraints), do: :term

  @impl Ash.Type
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(%OpaqueTree{} = value, _constraints), do: {:ok, value}
  def cast_input(_value, _constraints), do: :error

  @impl Ash.Type
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl Ash.Type
  def dump_to_native(value, constraints), do: cast_input(value, constraints)

  @impl Ash.Type
  def matches_type?(nil, _constraints), do: true
  def matches_type?(value, _constraints), do: is_struct(value, OpaqueTree)
end

defmodule AshUi.ReloadContractTest.Page do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshUi],
    validate_domain_inclusion?: false

  alias AshUi.ReloadContractTest.{ManualRows, Row, RowsDigest}

  ets do
    private?(true)
  end

  attributes do
    attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
    attribute(:page_key, :string, allow_nil?: false, default: "p", public?: true)
    attribute(:q, :string, allow_nil?: false, default: "", public?: true)
    attribute(:draft, :string, allow_nil?: false, default: "", public?: true)

    attribute(
      :opaque_tree,
      AshUi.ReloadContractTest.OpaqueTreeType,
      public?: true
    )
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  relationships do
    has_many :rows, Row do
      source_attribute(:page_key)
      destination_attribute(:page_key)
    end

    has_many :filtered_rows, Row do
      no_attributes?(true)
      filter(expr(page_key == parent(:page_key)))
    end

    has_many :manual_rows, Row do
      no_attributes?(true)
      manual({ManualRows, depends_on: [:q]})
    end

    has_many :manual_opaque, Row do
      no_attributes?(true)
      manual(ManualRows)
    end
  end

  calculations do
    calculate(:shout, :string, expr(q <> "!"))
    calculate(:digest, :string, RowsDigest)

    calculate(
      :view,
      AshUi.Type.RenderTree,
      expr(
        section(:root, [part: :reload_root], [
          inline(:shout, [part: :reload_shout], [text(shout)]),
          inline(:digest, [part: :reload_digest], [text(digest)]),
          inline(:count, [part: :reload_count, data: %{n: row_count}], [text(page_key)]),
          list(:rows, [part: :reload_rows], [
            each(rows, :row, [], [
              item(:r, [part: :reload_row], [
                text(row.body),
                text(if(row.body_changed?, do: "changed", else: "unchanged"))
              ])
            ])
          ]),
          list(:filtered, [part: :reload_filtered], [
            each(filtered_rows, :frow, [], [item(:fr, [part: :reload_frow], [text(frow.body)])])
          ]),
          list(:manual, [part: :reload_manual], [
            each(manual_rows, :mrow, [], [item(:mr, [part: :reload_mrow], [text(mrow.body)])])
          ]),
          list(:opaque, [part: :reload_opaque], [
            each(manual_opaque, :orow, [], [item(:or, [part: :reload_orow], [text(orow.body)])])
          ])
        ])
      )
    )
  end

  aggregates do
    count(:row_count, :rows)
  end

  actions do
    defaults([:read])

    create :mount do
    end

    update :type do
      require_atomic?(false)
      argument(:draft, :string, allow_nil?: false)
      change(set_attribute(:draft, arg(:draft)))
    end

    update :search do
      require_atomic?(false)
      argument(:q, :string, allow_nil?: false)
      change(set_attribute(:q, arg(:q)))
    end

    update :replace_opaque_tree do
      require_atomic?(false)

      argument(
        :opaque_tree,
        AshUi.ReloadContractTest.OpaqueTreeType,
        allow_nil?: false
      )

      change(set_attribute(:opaque_tree, arg(:opaque_tree)))
    end
  end
end

defmodule AshUi.ReloadContractTest do
  use ExUnit.Case, async: false

  alias AshUi.Reload
  alias AshUi.ReloadContractTest.{OpaqueNode, OpaqueTree, Page, Row}

  setup do
    on_exit(fn ->
      Ash.DataLayer.Ets.stop(Page)
      Ash.DataLayer.Ets.stop(Row)
    end)
  end

  defp index, do: Map.new(Reload.view_dependency_index(Page))

  defp seed_page do
    Page
    |> Ash.Seed.seed!(%{session_id: Ash.UUID.generate(), page_key: "p", q: "q0", draft: "d0"})
    |> Ash.load!(AshUi.view_load(Page),
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
  end

  defp seed_row(body) do
    Row
    |> Ash.Changeset.for_create(:create, %{page_key: "p", body: body},
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.create!(domain: AshUi.AshDomainFallback)
  end

  defp run!(page, action, args) do
    page
    |> Ash.Changeset.for_update(action, args,
      domain: AshUi.AshDomainFallback,
      authorize?: false
    )
    |> Ash.update!(domain: AshUi.AshDomainFallback)
  end

  describe "view dependency index" do
    test "declarative relationship depends on its source_attribute" do
      assert %{attributes: attrs, relationships: rels} = index()[:rows]
      assert MapSet.to_list(attrs) == [:page_key]
      assert MapSet.size(rels) == 0
    end

    test "no_attributes? relationship depends on its parent() filter refs" do
      assert %{attributes: attrs, relationships: rels} = index()[:filtered_rows]
      assert MapSet.to_list(attrs) == [:page_key]
      assert MapSet.size(rels) == 0
    end

    test "manual relationship honors its declared depends_on" do
      assert %{attributes: attrs} = index()[:manual_rows]
      assert MapSet.to_list(attrs) == [:q]
    end

    test "manual relationship without depends_on stays conservative" do
      assert index()[:manual_opaque] == :all
    end

    test "expression calculation depends on its referenced attributes" do
      assert %{attributes: attrs} = index()[:shout]
      assert MapSet.to_list(attrs) == [:q]
    end

    test "module calculation declares its dependencies through load/3" do
      assert %{attributes: attrs, relationships: rels} = index()[:digest]
      assert MapSet.size(attrs) == 0
      assert MapSet.to_list(rels) == [:rows]
    end

    test "aggregate depends on its path edge and is data-invalidated by it" do
      assert %{attributes: attrs, relationships: rels} = index()[:row_count]
      assert MapSet.to_list(attrs) == [:page_key]
      assert MapSet.to_list(rels) == [:rows]
    end
  end

  describe "dependent roots" do
    test "a draft keystroke invalidates only the conservative root" do
      assert Reload.dependent_roots_for_attributes(Page, [:draft]) == [:manual_opaque]
    end

    test "a q change invalidates the declared q dependents" do
      roots = Reload.dependent_roots_for_attributes(Page, [:q])
      assert Enum.sort(roots) == [:manual_opaque, :manual_rows, :shout]
    end

    test "a page_key change invalidates the filtered reads and the aggregate" do
      roots = Reload.dependent_roots_for_attributes(Page, [:page_key])
      assert Enum.sort(roots) == [:filtered_rows, :manual_opaque, :row_count, :rows]
    end

    test "a data change on :rows invalidates the derived roots" do
      roots = Reload.dependent_roots_for_paths(Page, [[:rows]])
      assert Enum.sort(roots) == [:digest, :row_count]
    end
  end

  describe "after_dispatch" do
    test "a draft keystroke keeps unaffected loads pointer-identical" do
      seed_row("a")
      page = seed_page()

      updated = run!(page, :type, %{draft: "d"})
      assert {:ok, refreshed} = Reload.after_dispatch(page, updated, [], authorize?: false)

      assert refreshed.draft == "d"
      # Untouched view dependencies survive as the same terms — the O(1) half
      # of the contract (no reload, no re-walk).
      assert refreshed.rows == page.rows
      assert refreshed.digest == page.digest
      assert refreshed.row_count == page.row_count
    end

    test "a q change re-evaluates exactly the declared q dependents" do
      seed_row("a")
      page = seed_page()
      assert page.shout == "q0!"

      updated = run!(page, :search, %{q: "hi"})
      assert {:ok, refreshed} = Reload.after_dispatch(page, updated, [], authorize?: false)

      assert refreshed.shout == "hi!"
      assert refreshed.rows == page.rows
    end

    test "an echoed data path reloads the relationship and its derived roots" do
      seed_row("a")
      page = seed_page()
      assert page.row_count == 1
      assert page.digest == "a"

      seed_row("b")
      assert {:ok, refreshed} = Reload.after_dispatch(page, page, [[:rows]], authorize?: false)

      assert Enum.map(refreshed.rows, & &1.body) |> Enum.sort() == ["a", "b"]
      assert refreshed.row_count == 2
      assert refreshed.digest |> String.split(",") |> Enum.sort() == ["a", "b"]
    end

    test "an echoed data path recalculates already-loaded destination calculations" do
      row = seed_row("a")
      page = seed_page()
      refute hd(page.rows).body_changed?

      row
      |> Ash.Changeset.for_update(:update, %{body: "b"},
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )
      |> Ash.update!(domain: AshUi.AshDomainFallback)

      assert {:ok, refreshed} = Reload.after_dispatch(page, page, [[:rows]], authorize?: false)
      assert hd(refreshed.rows).body_changed?
    end

    test "a :root echo adds no data reload — the dispatch result is authoritative" do
      seed_row("a")
      page = seed_page()

      updated = run!(page, :type, %{draft: "x"})
      assert {:ok, refreshed} = Reload.after_dispatch(page, updated, :root, authorize?: false)

      assert refreshed.draft == "x"
      assert refreshed.rows == page.rows
    end

    test "typed non-resource structs are opaque values during load preservation" do
      old_tree = %OpaqueTree{nodes: [%OpaqueNode{id: "old", label: "before"}]}

      page =
        Page
        |> Ash.Seed.seed!(%{
          session_id: Ash.UUID.generate(),
          page_key: "p",
          q: "q0",
          draft: "d0",
          opaque_tree: old_tree
        })
        |> Ash.load!(AshUi.view_load(Page),
          domain: AshUi.AshDomainFallback,
          authorize?: false
        )

      new_tree = %OpaqueTree{nodes: [%OpaqueNode{id: "new", label: "after"}]}
      updated = run!(page, :replace_opaque_tree, %{opaque_tree: new_tree})

      assert {:ok, refreshed} = Reload.after_dispatch(page, updated, [], authorize?: false)
      assert refreshed.opaque_tree == new_tree
    end
  end
end
