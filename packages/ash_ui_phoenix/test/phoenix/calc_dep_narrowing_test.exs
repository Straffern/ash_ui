defmodule AshUi.Phoenix.CalcDepNarrowingTest do
  @moduledoc """
  Bridge-loop coverage for declaration-derived CALCULATION dependencies (the
  canonical reload contract in `AshUi.Reload`): a page carrying a
  derived root calculation over a relationship — the flattened-rows /
  date-sections shape — must repaint that calculation when the relationship
  changes through either an external notification or a dispatch echo. The view
  deliberately never references the source relationship directly.
  """

  use ExUnit.Case, async: false

  alias AshUi.Notification.MatchIndex
  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveViewTest.Diff, as: Client

  @counter_table :bp_calc_narrowing_read_counts

  defmodule Row do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      notifiers: [AshUi.Notifier],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:conversation_id, :uuid, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read])

      read :bench_relationship do
        prepare(fn query, _context ->
          :ets.update_counter(:bp_calc_narrowing_read_counts, :rows, 1, {:rows, 0})
          query
        end)
      end

      create :create do
        primary?(true)
        accept([:conversation_id, :body])
      end
    end
  end

  defmodule Digest do
    @moduledoc false
    # The derived-root module calculation: `load/3` IS its dependency
    # declaration (the date-sections analog — derived entirely from :rows).
    use Ash.Resource.Calculation

    @impl true
    def load(_query, _opts, _context), do: [rows: [:body]]

    @impl true
    def calculate(records, _opts, _context) do
      Enum.map(records, fn record ->
        record.rows |> List.wrap() |> Enum.map(& &1.body) |> Enum.sort() |> Enum.join("|")
      end)
    end
  end

  defmodule Page do
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
      attribute(:conversation_id, :uuid, allow_nil?: false, public?: true)
      attribute(:draft, :string, allow_nil?: true, default: "", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :rows, AshUi.Phoenix.CalcDepNarrowingTest.Row do
        source_attribute(:conversation_id)
        destination_attribute(:conversation_id)
        read_action(:bench_relationship)
      end
    end

    actions do
      defaults([:read, :destroy])

      create :mount do
        argument(:conversation_id, :uuid, allow_nil?: false)
        change(set_attribute(:conversation_id, arg(:conversation_id)))
      end

      update :type do
        require_atomic?(false)
        argument(:value, :string, allow_nil?: false)
        change(set_attribute(:draft, arg(:value)))
      end

      update :send do
        require_atomic?(false)

        change(fn changeset, context ->
          Ash.Changeset.after_action(changeset, fn _changeset, record ->
            _row =
              AshUi.Phoenix.CalcDepNarrowingTest.Row
              |> Ash.Changeset.for_create(
                :create,
                %{conversation_id: record.conversation_id, body: "sent"},
                Keyword.merge(
                  [domain: AshUi.AshDomainFallback],
                  Ash.Scope.to_opts(context)
                )
              )
              |> Ash.create!()

            {:ok, record}
          end)
        end)

        change(set_attribute(:draft, ""))
      end
    end

    calculations do
      calculate(:digest, :string, AshUi.Phoenix.CalcDepNarrowingTest.Digest)

      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [part: :calcdep_root], [
            inline(:digest, [part: :calcdep_digest], [text(digest)]),
            box(:composer, [part: :calcdep_composer], [
              button(
                :type,
                [
                  type: :button,
                  part: :calcdep_type,
                  on_click: :type,
                  action_input: %{value: "d"}
                ],
                [text(draft)]
              ),
              button(:send, [type: :button, part: :calcdep_send, on_click: :send], [text("send")])
            ])
          ])
        )
      )
    end
  end

  setup do
    if :ets.whereis(@counter_table) == :undefined do
      :ets.new(@counter_table, [:named_table, :public, :set])
    end

    :ets.delete_all_objects(@counter_table)
    MatchIndex.reset()

    on_exit(fn ->
      Ash.DataLayer.Ets.stop(Page)
      Ash.DataLayer.Ets.stop(Row)
    end)

    :ok
  end

  defp row_reads do
    case :ets.lookup(@counter_table, :rows) do
      [{:rows, n}] -> n
      [] -> 0
    end
  end

  defp mount_page do
    session_id = Ash.UUID.generate()
    conversation_id = Ash.UUID.generate()

    for body <- ["a", "b"] do
      Row
      |> Ash.Changeset.for_create(:create, %{conversation_id: conversation_id, body: body},
        domain: AshUi.AshDomainFallback
      )
      |> Ash.create!()
    end

    Process.put(:"$callers", [self()])

    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}},
      private: %{}
    }

    {:ok, socket} =
      AshUi.Phoenix.mount(
        Page,
        %{"conversation_id" => conversation_id},
        %{"ash_ui_session_id" => session_id},
        socket,
        otp_app: :ash_ui_phoenix
      )

    # The transport pid and `$callers` entry make this the CONNECTED mount:
    # it registers the page's subscriptions itself, including the key-matched
    # :rows subscription derived from `Digest.load/3` (the relationship is a
    # hidden calc dependency, never loaded on the record).
    socket
  end

  defp binding_for_part(socket, part) do
    rendered = AshUi.Phoenix.render_shell(socket.assigns)
    lv_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {diff, _prints, _components} =
      Phoenix.LiveView.Diff.render(
        lv_socket,
        rendered,
        Phoenix.LiveView.Diff.new_fingerprints(),
        Phoenix.LiveView.Diff.new_components()
      )

    html =
      %{}
      |> Phoenix.LiveViewTest.Diff.merge_diff(diff)
      |> Map.delete(:streams)
      |> Phoenix.LiveView.Diff.to_iodata()
      |> IO.iodata_to_binary()

    chunk =
      html
      |> String.split("<button")
      |> Enum.find(&String.contains?(&1, ~s(part="#{part}")))

    [_, key] = Regex.run(~r/ash_ui:dispatch:([A-Za-z0-9+\/=._-]+)"/, chunk)
    key
  end

  defp dispatch!(socket, binding_key) do
    {:noreply, socket} =
      AshUi.Phoenix.runtime_handle_event(
        "ash_ui:dispatch",
        %{"binding" => binding_key},
        socket
      )

    socket
  end

  defp render(socket, prints) do
    rendered = AshUi.Phoenix.render_shell(socket.assigns)
    lv_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {diff, prints, _components} =
      Diff.render(
        lv_socket,
        rendered,
        prints || Diff.new_fingerprints(),
        Diff.new_components()
      )

    {diff, prints}
  end

  defp paint(client) do
    client
    |> Map.delete(:streams)
    |> Diff.to_iodata()
    |> IO.iodata_to_binary()
  end

  test "a relationship notification ships a patch for its calc-only view dependency" do
    socket = mount_page()
    record = socket.assigns.ash_ui_record
    assert record.digest == "a|b"

    {full, prints} = render(socket, nil)
    client = Client.merge_diff(%{}, full)
    assert paint(client) =~ "a|b"

    reads_before = row_reads()
    assert %Ash.NotLoaded{} = record.rows
    [{subscription_ref, subscription}] = MatchIndex.subs_for(Row)
    assert subscription.attrs == [conversation_id: record.conversation_id]

    Row
    |> Ash.Changeset.for_create(
      :create,
      %{conversation_id: record.conversation_id, body: "notified"},
      domain: AshUi.AshDomainFallback
    )
    |> Ash.create!()

    assert_receive {:ash_ui_notification, ^subscription_ref, _event} = notification
    assert {:noreply, socket} = AshUi.Phoenix.runtime_handle_info(notification, socket)

    assert socket.assigns.ash_ui_record.digest == "a|b|notified"
    assert row_reads() > reads_before
    assert MapSet.size(socket.assigns.ash_ui_changed) > 0

    {patch, _prints} = render(socket, prints)
    client = Client.merge_diff(client, patch)

    assert patch != %{}
    assert inspect(patch) =~ "notified"
    assert paint(client) =~ "a|b|notified"

    reads_before = row_reads()
    socket = dispatch!(socket, binding_for_part(socket, "calcdep_type"))

    assert socket.assigns.ash_ui_record.draft == "d"
    assert socket.assigns.ash_ui_record.digest == "a|b|notified"
    assert row_reads() == reads_before
  end

  test "a root notification reuses unchanged loaded relationship branches" do
    socket = mount_page()

    record =
      Ash.load!(socket.assigns.ash_ui_record, [rows: [:body]],
        domain: AshUi.AshDomainFallback
      )

    socket = put_in(socket.assigns.ash_ui_record, record)

    assert {:ok, _updated} =
             record
             |> Ash.Changeset.for_update(:type, %{value: "root changed"},
               domain: AshUi.AshDomainFallback
             )
             |> Ash.update()

    subscription_ref = {:calc_dep_root, self(), record.session_id}

    assert :ok =
             MatchIndex.register(subscription_ref, %{
               pid: self(),
               resource: Page,
               attrs: [session_id: record.session_id],
               reload_scope: :root,
               tenant: nil
             })

    notification =
      {:ash_ui_notification, subscription_ref,
       %{resource: Page, type: :update, old: record}}

    for arity <- [2, 3] do
      :erlang.trace_pattern({Ash.DataLayer.Ets, :run_query, arity}, true, [:call_count])
    end

    try do
      assert {:noreply, socket} = AshUi.Phoenix.runtime_handle_info(notification, socket)
      assert socket.assigns.ash_ui_record.draft == "root changed"
      assert socket.assigns.ash_ui_record.digest == "a|b"

      query_calls =
        Enum.sum_by([2, 3], fn arity ->
          {:call_count, count} =
            :erlang.trace_info({Ash.DataLayer.Ets, :run_query, arity}, :call_count)

          count
        end)

      # One logical root-row read passes through the public /2 wrapper and the
      # ETS implementation's default-argument /3 clause. A child reload would
      # add another pair and make this scale with loaded relationship volume.
      assert query_calls == 2
    after
      for arity <- [2, 3] do
        :erlang.trace_pattern({Ash.DataLayer.Ets, :run_query, arity}, false, [:call_count])
      end
    end
  end

  test "a dispatch echo ships a patch for its calc-only view dependency" do
    socket = mount_page()
    assert socket.assigns.ash_ui_record.digest == "a|b"

    {full, prints} = render(socket, nil)
    client = Client.merge_diff(%{}, full)

    socket = dispatch!(socket, binding_for_part(socket, "calcdep_send"))
    refreshed = socket.assigns.ash_ui_record

    assert refreshed.digest |> String.split("|") |> Enum.sort() == ["a", "b", "sent"]
    assert MapSet.size(socket.assigns.ash_ui_changed) > 0

    {patch, _prints} = render(socket, prints)
    client = Client.merge_diff(client, patch)

    assert patch != %{}
    assert inspect(patch) =~ "sent"
    assert paint(client) =~ "a|b|sent"
  end
end
