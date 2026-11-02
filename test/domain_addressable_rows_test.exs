defmodule AshUi.DomainAddressableRowsTest do
  use ExUnit.Case, async: false

  alias AshUi.EventBinding
  alias AshUi.Patch.Bindings
  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Dispatch

  defmodule Artist do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      validate_domain_inclusion?: false,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private?(true)
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      attribute(:id, :string, allow_nil?: false, primary_key?: true, public?: true)
      attribute(:owner_id, :string, allow_nil?: false, public?: true)
      attribute(:name, :string, allow_nil?: false, public?: true)
      attribute(:visible?, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:followed?, :boolean, allow_nil?: false, default: false, public?: true)
      attribute(:rank, :integer, public?: true)
    end

    actions do
      defaults([:read, :destroy, create: :*])

      update :follow do
        require_atomic?(false)
        argument(:rank, :integer, allow_nil?: false)
        change(set_attribute(:followed?, true))
        change(set_attribute(:rank, arg(:rank)))
      end

      action :ping, :string do
        run(fn _input, _context -> {:ok, "pong"} end)
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource Artist do
        define(:follow_artist,
          action: :follow,
          get_by: [:id, :owner_id, :visible?],
          args: [:rank]
        )

        define(:destroy_artist,
          action: :destroy,
          get_by: [:id, :owner_id, :visible?]
        )
      end
    end
  end

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private?(true)
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:owner_id, :string, allow_nil?: false, public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :artists, Artist do
        source_attribute(:owner_id)
        destination_attribute(:owner_id)
        filter(expr(visible? == true))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          each(artists, :artist, [key: artist.id], [
            button(
              :follow_btn,
              [
                on_click: :follow_artist,
                action_input: %{artist_id: artist.id, rank: event(:button)}
              ],
              [text(artist.name)]
            ),
            button(
              :destroy_btn,
              [on_click: :destroy_artist, action_input: %{artist_id: artist.id}],
              [text("destroy")]
            )
          ])
        )
      )
    end

    actions do
      update :follow_artist do
        require_atomic?(false)

        argument(:artist_id, :string, allow_nil?: false)
        argument(:rank, :integer, allow_nil?: false)

        change(fn changeset, context ->
          case Domain.follow_artist(
                 changeset.arguments.artist_id,
                 changeset.data.owner_id,
                 true,
                 changeset.arguments.rank,
                 scope: context
               ) do
            {:ok, _artist} -> changeset
            {:error, error} -> Ash.Changeset.add_error(changeset, error)
          end
        end)
      end

      update :destroy_artist do
        require_atomic?(false)

        argument(:artist_id, :string, allow_nil?: false)

        change(fn changeset, context ->
          case Domain.destroy_artist(
                 changeset.arguments.artist_id,
                 changeset.data.owner_id,
                 true,
                 scope: context
               ) do
            :ok -> changeset
            {:ok, _artist} -> changeset
            {:error, error} -> Ash.Changeset.add_error(changeset, error)
          end
        end)
      end
    end
  end

  defmodule EmbeddedItem do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false,
      authorizers: [Ash.Policy.Authorizer]

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      attribute(:id, :string, allow_nil?: false, primary_key?: true, public?: true)
      attribute(:active?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])

      update :toggle do
        require_atomic?(false)

        validate(fn changeset, _context ->
          if changeset.data.id == "blocked" do
            {:error, field: :id, message: "cannot toggle blocked entry"}
          else
            :ok
          end
        end)

        change(fn changeset, _context ->
          Ash.Changeset.change_attribute(changeset, :active?, !changeset.data.active?)
        end)
      end
    end

    calculations do
      calculate(:view, AshUi.Type.RenderTree, expr(text(id)))
    end
  end

  defmodule EmbeddedPage do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false,
      authorizers: [Ash.Policy.Authorizer]

    ets do
      private?(true)
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)

      attribute :rows, {:array, EmbeddedItem} do
        allow_nil?(false)
        default([])
        public?(true)
        constraints(items: [update_action: :toggle])
      end
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:update])

      update :toggle_row do
        require_atomic?(false)

        argument(:row_id, :string, allow_nil?: false)

        change(fn changeset, _context ->
          row_id = changeset.arguments.row_id

          if Enum.any?(changeset.data.rows, &(&1.id == row_id)) do
            rows =
              Enum.map(changeset.data.rows, fn
                %{id: ^row_id} -> %{id: row_id}
                row -> row
              end)

            Ash.Changeset.change_attribute(changeset, :rows, rows)
          else
            Ash.Changeset.add_error(changeset,
              field: :row_id,
              message: "does not identify an existing embedded row"
            )
          end
        end)
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          each(rows, :row, [key: row.id], [
            button(
              :toggle_btn,
              [on_click: :toggle_row, action_input: %{row_id: row.id}],
              [text(row.id)]
            )
          ])
        )
      )
    end
  end

  setup do
    owner_id = Ash.UUID.generate()
    page = Ash.Seed.seed!(Page, %{session_id: Ash.UUID.generate(), owner_id: owner_id})

    visible = create_artist!(owner_id, "visible", true)
    hidden = create_artist!(owner_id, "hidden", false)
    other = create_artist!(Ash.UUID.generate(), "other-owner", true)

    {:ok, page} =
      Ash.load(page, :artists,
        domain: AshUi.AshDomainFallback,
        authorize?: false
      )

    %{page: page, visible: visible, hidden: hidden, other: other}
  end

  test "typed page action updates the selected relationship row", %{
    page: page,
    visible: visible
  } do
    table = Compiler.table(Page)
    key = binding_key(table, visible.id, :follow_artist)

    assert {:ok, %EventBinding{ui_event: :follow_artist} = binding, {:root}} =
             Bindings.resolve(page, key, %{"button" => "7"}, table: table)

    assert binding.args_exprs == %{
             artist_id: visible.id,
             rank: {:event, :button}
           }

    assert {:dispatch, [], :follow_artist, %{artist_id: "visible", rank: "7"} = payload} =
             EventBinding.runtime_event(binding, %{"button" => "7"})

    assert {:ok, %Page{}} = Dispatch.run(page, {:root}, :follow_artist, payload)

    updated = Ash.get!(Artist, visible.id, domain: AshUi.AshDomainFallback)
    assert updated.followed?
    assert updated.rank == 7
  end

  test "typed page action destroys the selected relationship row", %{
    page: page,
    visible: visible
  } do
    table = Compiler.table(Page)
    key = binding_key(table, visible.id, :destroy_artist)

    assert {:ok, %EventBinding{ui_event: :destroy_artist}, {:root}} =
             Bindings.resolve(page, key, %{}, table: table)

    assert {:ok, %Page{}} =
             Dispatch.run(page, {:root}, :destroy_artist, %{artist_id: visible.id})

    refute Enum.any?(
             Ash.read!(Artist, domain: AshUi.AshDomainFallback),
             &(&1.id == visible.id)
           )
  end

  test "a stale row outside the relationship filter is an ordinary page action error",
       %{
         page: page,
         hidden: hidden
       } do
    stale_projection = %{page | artists: [hidden]}
    key = binding_key(Compiler.table(Page), hidden.id, :follow_artist)

    assert {:ok, %EventBinding{}, {:root}} =
             Bindings.resolve(stale_projection, key, %{"button" => "1"})

    assert {:error, error} =
             Dispatch.run(stale_projection, {:root}, :follow_artist, %{
               artist_id: hidden.id,
               rank: "1"
             })

    refute Exception.message(error) =~ "forbidden"
    refute Ash.get!(Artist, hidden.id, domain: AshUi.AshDomainFallback).followed?
  end

  test "a deleted row retained by a stale page projection is an ordinary page action error", %{
    page: page,
    visible: visible
  } do
    key = binding_key(Compiler.table(Page), visible.id, :follow_artist)
    Ash.destroy!(visible, action: :destroy, domain: AshUi.AshDomainFallback)

    assert {:ok, %EventBinding{}, {:root}} = Bindings.resolve(page, key, %{"button" => "1"})

    assert {:error, _error} =
             Dispatch.run(page, {:root}, :follow_artist, %{
               artist_id: visible.id,
               rank: "1"
             })
  end

  test "an embedded page action uses the parent cast and embedded update action" do
    page =
      Ash.Seed.seed!(EmbeddedPage, %{
        session_id: Ash.UUID.generate(),
        rows: [%{id: "a", active?: false}, %{id: "b", active?: false}]
      })

    table = Compiler.table(EmbeddedPage)
    key = binding_key(table, "b", :toggle_row)

    assert {:ok, %EventBinding{ui_event: :toggle_row}, {:root}} =
             Bindings.resolve(page, key, %{}, table: table)

    assert {:ok, %EmbeddedPage{} = updated} =
             Dispatch.run(page, {:root}, :toggle_row, %{row_id: "b"})

    assert Enum.find(updated.rows, &(&1.id == "b")).active?
    refute Enum.find(updated.rows, &(&1.id == "a")).active?
  end

  test "embedded validations surface through the parent action without persisting" do
    page =
      Ash.Seed.seed!(EmbeddedPage, %{
        session_id: Ash.UUID.generate(),
        rows: [%{id: "blocked", active?: false}]
      })

    assert {:error, error} =
             Dispatch.run(page, {:root}, :toggle_row, %{row_id: "blocked"})

    assert Exception.message(error) =~ "cannot toggle blocked entry"

    persisted =
      Ash.get!(EmbeddedPage, page.session_id, domain: AshUi.AshDomainFallback)

    refute hd(persisted.rows).active?
  end

  test "a missing embedded key is an ordinary page action error" do
    page =
      Ash.Seed.seed!(EmbeddedPage, %{
        session_id: Ash.UUID.generate(),
        rows: [%{id: "present", active?: false}]
      })

    assert {:error, error} =
             Dispatch.run(page, {:root}, :toggle_row, %{row_id: "missing"})

    assert Exception.message(error) =~ "does not identify an existing embedded row"
  end

  test "event index contains declaration events without tuple target metadata" do
    entries = Page |> Compiler.table() |> Map.fetch!(:event_elements) |> Map.values()

    refute Enum.any?(entries, &Map.has_key?(&1, :targets))

    actions =
      entries
      |> Enum.flat_map(&List.wrap(&1.node.events))
      |> Enum.map(& &1.ui_event)

    assert :follow_artist in actions
    assert :destroy_artist in actions
  end

  test "event bindings retain the enclosing relationship as their scoped reload path", %{
    visible: visible
  } do
    table = Compiler.table(Page)

    for action <- [:follow_artist, :destroy_artist] do
      key = binding_key(table, visible.id, action)
      assert Compiler.dispatch_reload_paths(key, table) == [[:artists]]
    end
  end

  test "item-tuple bindings are a compile error with the one-form replacement" do
    assert_tuple_compile_error(
      "each(artists, :artist, [key: artist.id], [button(:bad, [on_click: {artist, :follow}], [text(\"bad\")])])"
    )
  end

  defp binding_key(table, entry_key, action) do
    {addr, event} =
      Enum.find_value(table.event_elements, fn {addr, entry} ->
        Enum.find_value(List.wrap(entry.node.events), fn binding ->
          if binding.ui_event == action, do: {addr, binding.dom_event}
        end)
      end)

    Enum.join(
      [EventBinding.key_component(entry_key), Compiler.addr_component(addr), event],
      "."
    )
  end

  defp create_artist!(owner_id, id, visible?) do
    Artist
    |> Ash.Changeset.for_create(
      :create,
      %{id: id, owner_id: owner_id, name: id, visible?: visible?},
      domain: AshUi.AshDomainFallback
    )
    |> Ash.create!()
  end

  defp assert_tuple_compile_error(view) do
    module = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
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
        attribute(:owner_id, :string, allow_nil?: false, public?: true)
      end

      identities do
        identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
      end

      relationships do
        has_many :artists, #{inspect(Artist)} do
          source_attribute(:owner_id)
          destination_attribute(:owner_id)
        end
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(#{view}))
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end

    assert Exception.message(error) =~ "item-tuple event bindings are not supported"
    assert Exception.message(error) =~ "bare action atom"
    assert Exception.message(error) =~ "typed action_input"
    assert Exception.message(error) =~ "page action"
  end
end
