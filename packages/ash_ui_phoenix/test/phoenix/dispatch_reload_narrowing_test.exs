defmodule AshUi.Phoenix.DispatchReloadNarrowingTest do
  @moduledoc """
  Latency fixture: the read-cost contract of post-dispatch reloads, measured
  through the REAL bridge loop (mounted socket -> browser-shaped dispatch ->
  runtime_handle_event -> refresh) with counting reads.

  The page mirrors the messaging viewer's structure — the hot bindings are
  authored INSIDE an `each` over a relationship, and the page carries several
  independent relationship reads — because that is the shape where reload
  narrowing must hold:

    * an attribute-only dispatch (composer keystroke analog) reloads ZERO
      relationships;
    * a dispatch whose action writes one related resource reloads ONLY the
      relationships reading that resource.

  Each test also prints a wall-clock table (µs) for the dispatch so burn-down
  work has a stable, browser-free measurement.
  """

  use ExUnit.Case, async: false

  alias AshUi.Notification.MatchIndex
  alias Phoenix.LiveView.Diff
  alias Phoenix.LiveViewTest.Diff, as: Client

  @counter_table :bp_narrowing_read_counts

  defmodule RowA do
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
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
      # Extra transcript fields so a per-row re-render ships real dynamic bytes
      # — the messaging shape where the composer's each wraps a rich transcript.
      attribute(:author, :string, allow_nil?: false, default: "", public?: true)
      attribute(:body, :string, allow_nil?: false, default: "", public?: true)
      attribute(:ts, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read])

      read :bench_relationship do
        prepare(fn query, _context ->
          :ets.update_counter(:bp_narrowing_read_counts, :row_a, 1, {:row_a, 0})
          query
        end)
      end

      create :create do
        primary?(true)
        accept([:conversation_id, :label, :author, :body, :ts])
      end
    end
  end

  defmodule RowB do
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
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
      # Conversation-chrome fields: the shell entry renders these FLAT (a
      # header, topic bar, participant summary) around the transcript and
      # composer, exactly as messaging's conversation entry does.
      attribute(:title, :string, allow_nil?: false, default: "", public?: true)
      attribute(:subtitle, :string, allow_nil?: false, default: "", public?: true)
      attribute(:topic, :string, allow_nil?: false, default: "", public?: true)
      attribute(:status, :string, allow_nil?: false, default: "", public?: true)
      attribute(:description, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read])

      read :bench_relationship do
        prepare(fn query, _context ->
          :ets.update_counter(:bp_narrowing_read_counts, :row_b, 1, {:row_b, 0})
          {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
          :ets.insert(:bp_narrowing_read_counts, {:row_b_stack, stack})
          query
        end)
      end

      create :create do
        primary?(true)
        accept([:conversation_id, :label, :title, :subtitle, :topic, :status, :description])
      end
    end
  end

  defmodule RowC do
    @moduledoc false
    # The mention-suggestion source: a relationship whose rows depend on a page
    # attribute through `parent(...)` in its filter (the mention_query analog).
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
      attribute(:topic, :string, allow_nil?: false, default: "", public?: true)
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
    end

    actions do
      defaults([:read])

      read :bench_relationship do
        prepare(fn query, _context ->
          :ets.update_counter(:bp_narrowing_read_counts, :row_c, 1, {:row_c, 0})
          query
        end)
      end

      create :create do
        primary?(true)
        accept([:conversation_id, :topic, :label])
      end
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
      attribute(:composer_text, :string, allow_nil?: true, default: "", public?: true)
      attribute(:mention_query, :string, allow_nil?: true, default: "", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    relationships do
      has_many :rows_a, AshUi.Phoenix.DispatchReloadNarrowingTest.RowA do
        source_attribute(:conversation_id)
        destination_attribute(:conversation_id)
        read_action(:bench_relationship)
      end

      has_many :rows_b, AshUi.Phoenix.DispatchReloadNarrowingTest.RowB do
        source_attribute(:conversation_id)
        destination_attribute(:conversation_id)
        read_action(:bench_relationship)
      end

      # Mention-suggestion read: keyed on conversation_id, but its rows also
      # depend on the page's `mention_query` through a parent() filter — the
      # keystroke shape where a query change must reload ONLY this relationship.
      has_many :mentions, AshUi.Phoenix.DispatchReloadNarrowingTest.RowC do
        source_attribute(:conversation_id)
        destination_attribute(:conversation_id)
        read_action(:bench_relationship)
        filter(expr(topic == parent(mention_query)))
      end
    end

    actions do
      defaults([:read, :destroy])

      create :mount do
        argument(:conversation_id, :uuid, allow_nil?: false)
        change(set_attribute(:conversation_id, arg(:conversation_id)))
      end

      # Composer keystroke analog: attribute-only update, no related writes.
      update :poke do
        require_atomic?(false)
        argument(:value, :string, allow_nil?: false)
        change(set_attribute(:composer_text, arg(:value)))
      end

      # The textarea's on_input target, messaging-faithful: accepts the bound
      # field by name (auto-bound from the control's `name: :composer_text`).
      update :update_composer do
        require_atomic?(false)
        accept([:composer_text])
      end

      # Focus/blur analog (messaging: start_typing/stop_typing) — no arguments.
      update :touch do
        require_atomic?(false)
      end

      # Mention keystroke analog: attribute-only update, but the attribute is
      # one a parent()-filtered relationship depends on, so exactly that
      # relationship (mentions) must reload and nothing else.
      update :set_mention_query do
        require_atomic?(false)
        argument(:value, :string, allow_nil?: false)
        change(set_attribute(:mention_query, arg(:value)))
      end

      # Send analog: writes ONE RowA and clears the composer.
      update :send do
        require_atomic?(false)

        change(fn changeset, context ->
          Ash.Changeset.after_action(changeset, fn _changeset, record ->
            # scope: context propagates the dispatch ref through shared
            # changeset context — the same seam production domain calls use —
            # so the write's notification is a synchronous dispatch echo.
            _row =
              AshUi.Phoenix.DispatchReloadNarrowingTest.RowA
              |> Ash.Changeset.for_create(
                :create,
                %{
                  conversation_id: record.conversation_id,
                  label: "sent",
                  author: "me",
                  body: "sent message body",
                  ts: "2026-07-16T11:00:00Z"
                },
                Keyword.merge(
                  [domain: AshUi.AshDomainFallback],
                  Ash.Scope.to_opts(context)
                )
              )
              |> Ash.create!()

            {:ok, record}
          end)
        end)

        change(set_attribute(:composer_text, ""))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [part: :bench_root], [
            # An independent conversation-keyed relationship, kept so the read
            # tests can prove a RowA write does not reload the RowB read.
            list(:list_b, [part: :bench_list_b], [
              each(rows_b, :row_b, [key: row_b.id], [item(:row_b, [], [text(row_b.label)])])
            ]),
            # The mention suggestions read — a parent()-filtered relationship,
            # loaded by the view so it is a tracked view dependency.
            list(:list_mentions, [part: :bench_list_mentions], [
              each(mentions, :m, [key: m.id], [item(:m, [], [text(m.label)])])
            ]),
            # THE MESSAGING SHAPE: a single-row shell `each` (over rows_b, one
            # row) whose body wraps BOTH the rich transcript (an inner each over
            # the 24 rows_a messages, reading ROW fields only) AND the composer
            # (authored ONCE, reading composer_text — a PAGE attribute). Because
            # composer_text is read inside the shell each, it becomes a PARENT
            # dependency of that each: a keystroke invalidates the shell entry's
            # vars and — without diff scoping — LiveView re-ships the ENTIRE
            # enclosed subtree, transcript included (the 13KB-class blowup). The
            # fix must narrow the shell-entry re-render to the composer_text
            # slots so the 24 transcript rows never re-ship.
            #
            # The each sits inside an IF ARM, exactly as messaging's
            # conversation each does (empty-state placeholder vs. the real
            # conversation). A branch arm re-renders with `changed = :all`, so
            # the narrowing must not depend on the page-level changed set
            # reaching the keyed emit — the arm-nested each is the production
            # regression shape.
            if conversation_id == "00000000-0000-0000-0000-000000000000" do
              box(:empty_state, [part: :bench_empty_state], [
                text("No conversation selected")
              ])
            else
              each(rows_b, :shell, [key: shell.id], [
                box(:conversation, [part: :bench_conversation], [
                  # FLAT conversation chrome (header, topic, participant summary).
                  # These read SHELL fields only — never composer_text — so a
                  # keystroke leaves them unchanged. But because they are flat
                  # scalar slots inside the shell entry (whose parent var
                  # composer_text changed), an unscoped entry re-render re-ships
                  # ALL of them: the messaging blowup.
                  header(:convo_header, [part: :bench_convo_header, data: [id: shell.id]], [
                    heading(:title, [part: :bench_convo_title], [text(shell.title)]),
                    small(:subtitle, [part: :bench_convo_subtitle], [text(shell.subtitle)]),
                    small(:status, [part: :bench_convo_status, data: [status: shell.status]], [
                      text(shell.status)
                    ])
                  ]),
                  box(:topicbar, [part: :bench_topicbar, data: [topic: shell.topic]], [
                    strong(:topic_label, [part: :bench_topic_label], [text(shell.topic)]),
                    paragraph(:desc, [part: :bench_convo_desc], [text(shell.description)])
                  ]),
                  box(:summary, [part: :bench_convo_summary], [
                    small(:s1, [part: :bench_s1, data: [t: shell.title]], [text(shell.title)]),
                    small(:s2, [part: :bench_s2, data: [t: shell.subtitle]], [
                      text(shell.subtitle)
                    ]),
                    small(:s3, [part: :bench_s3, data: [t: shell.topic]], [text(shell.topic)]),
                    small(:s4, [part: :bench_s4, data: [t: shell.status]], [text(shell.status)]),
                    small(:s5, [part: :bench_s5, data: [t: shell.description]], [
                      text(shell.description)
                    ]),
                    small(:s6, [part: :bench_s6, data: [t: shell.label]], [text(shell.label)]),
                    # A participant/metadata strip — more flat header slots, the
                    # kind messaging's conversation entry carries (names, roles,
                    # counts). None read composer_text; all re-ship on an unscoped
                    # keystroke, pushing the blowup into the 13KB class.
                    small(:s7, [part: :bench_s7, data: [t: shell.title]], [
                      text(shell.description)
                    ]),
                    small(:s8, [part: :bench_s8, data: [t: shell.subtitle]], [
                      text(shell.description)
                    ]),
                    small(:s9, [part: :bench_s9, data: [t: shell.topic]], [
                      text(shell.description)
                    ]),
                    small(:s10, [part: :bench_s10, data: [t: shell.status]], [
                      text(shell.description)
                    ]),
                    small(:s11, [part: :bench_s11, data: [t: shell.title]], [text(shell.subtitle)]),
                    small(:s12, [part: :bench_s12, data: [t: shell.topic]], [text(shell.status)]),
                    small(:s13, [part: :bench_s13, data: [t: shell.description]], [
                      text(shell.title)
                    ]),
                    small(:s14, [part: :bench_s14, data: [t: shell.description]], [
                      text(shell.topic)
                    ]),
                    small(:s15, [part: :bench_s15, data: [t: shell.description]], [
                      text(shell.subtitle)
                    ]),
                    small(:s16, [part: :bench_s16, data: [t: shell.description]], [
                      text(shell.status)
                    ])
                  ]),
                  list(:transcript, [part: :bench_transcript], [
                    each(rows_a, :msg, [key: msg.id], [
                      item(:msg, [part: :bench_msgrow, data: [id: msg.id]], [
                        box(:avatar, [part: :bench_avatar, data: [author: msg.author]], [
                          text(msg.author)
                        ]),
                        strong(:author, [part: :bench_author], [text(msg.author)]),
                        small(:ts, [part: :bench_ts], [text(msg.ts)]),
                        paragraph(:body, [part: :bench_body, data: [label: msg.label]], [
                          text(msg.body)
                        ])
                      ])
                    ])
                  ]),
                  # The composer is a FORM (messaging: `form(:composer, [...,
                  # on_submit: :send_message], ...)`) whose inputbox BOX carries a
                  # data attribute reading composer_text (`data: %{empty:
                  # empty?(composer_text)}`) and wraps the value-bound,
                  # multi-binding textarea PLUS a toolbar of binding-bearing
                  # buttons (attach/emoji/mention/send with long binding-key
                  # attributes) that do NOT read composer_text. A keystroke must
                  # re-ship the inputbox attrs + textarea slots ONLY — never the
                  # toolbar buttons' binding attributes.
                  form(
                    :composer,
                    [part: :bench_composer, on_submit: :send],
                    [
                      box(
                        :inputbox,
                        [part: :bench_inputbox, data: %{empty: empty?(composer_text)}],
                        [
                          # The composer textarea, messaging-faithful: value-bound
                          # to composer_text, placeholder reading a parent-record
                          # field, data-empty reading composer_text, and FOUR
                          # event bindings (input/focus/blur/Enter-keydown).
                          textarea(:composer_text,
                            dom_id: "bench-main-composer",
                            part: :bench_composer_input,
                            name: :composer_text,
                            aria: %{label: "Message"},
                            placeholder: "Message " <> coalesce(shell.title, "conversation"),
                            data: %{empty: empty?(composer_text)},
                            value: composer_text,
                            on_input: :update_composer,
                            on_focus: :touch,
                            on_blur: :touch,
                            on_keydown: :send,
                            when: key("Enter"),
                            prevent_default: true
                          )
                        ]
                      ),
                      footer(:toolbar, [part: :bench_composer_toolbar], [
                        button(
                          :attach,
                          [
                            type: :button,
                            part: :bench_composer_tool,
                            aria: %{label: "Attach file"},
                            title: "Attach file",
                            on_click: :poke,
                            action_input: %{value: "attach"}
                          ],
                          [inline(:icon_attach, [part: :bench_icon_attach], [])]
                        ),
                        button(
                          :emoji,
                          [
                            type: :button,
                            part: :bench_composer_tool,
                            aria: %{label: "Add emoji"},
                            title: "Add emoji",
                            on_click: :poke,
                            action_input: %{value: "emoji"}
                          ],
                          [inline(:icon_emoji, [part: :bench_icon_emoji], [])]
                        ),
                        button(
                          :mention,
                          [
                            type: :button,
                            part: :bench_composer_tool,
                            aria: %{label: "Mention person or channel", haspopup: "listbox"},
                            title: "Mention",
                            on_click: :set_mention_query,
                            action_input: %{value: "@"}
                          ],
                          [inline(:icon_mention, [part: :bench_icon_mention], [])]
                        ),
                        button(
                          :poke,
                          [type: :button, on_click: :poke, action_input: %{value: "poked"}],
                          [text(composer_text)]
                        ),
                        button(
                          :send,
                          [
                            type: :button,
                            part: :bench_send_button,
                            aria: %{label: "Send message"},
                            title: "Send message",
                            on_click: :send
                          ],
                          [inline(:icon_send, [part: :bench_icon_send], [])]
                        )
                      ])
                    ]
                  )
                ])
              ])
            end,
            # The mention keystroke binding — sets mention_query, the attribute
            # the parent()-filtered `mentions` relationship depends on.
            box(:mention_composer, [part: :bench_mention_composer], [
              button(
                :set_mention_query,
                [type: :button, on_click: :set_mention_query, action_input: %{value: "ali"}],
                [text(mention_query)]
              )
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
    # The dispatch echo rides the notification transport: a clean MatchIndex
    # each test so no leftover subscription (from this or a sibling test)
    # routes a stray notification into this process's mailbox.
    MatchIndex.reset()
    :ok
  end

  defp counts do
    %{
      row_a: counter(:row_a),
      row_b: counter(:row_b),
      row_c: counter(:row_c)
    }
  end

  defp counter(key) do
    case :ets.lookup(@counter_table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  # The transcript size: the composer's each wraps this many rich rows. A
  # composer keystroke must NOT re-ship these rows — that is the blowup under
  # test (messaging's transcript is dozens of rows of per-row markup).
  @transcript_rows 24

  defp mount_page do
    session_id = Ash.UUID.generate()
    conversation_id = Ash.UUID.generate()

    for i <- 1..@transcript_rows do
      RowA
      |> Ash.Changeset.for_create(
        :create,
        %{
          conversation_id: conversation_id,
          label: "message-body-line-number-#{i}-lorem-ipsum",
          author: "author-name-#{i}",
          body: "the quick brown fox jumped over the lazy dog, row #{i}",
          ts: "2026-07-16T10:#{rem(i, 60)}:00Z"
        },
        domain: AshUi.AshDomainFallback
      )
      |> Ash.create!()
    end

    RowB
    |> Ash.Changeset.for_create(
      :create,
      %{
        conversation_id: conversation_id,
        label: "the-conversation-shell-label-value",
        title: "Design Review — Q3 Roadmap and Launch Planning Sync",
        subtitle: "42 participants · started 3 days ago · last active just now",
        topic: "Topic: finalize the launch checklist and assign remaining owners",
        status: "online · 12 members active · 4 typing · synced",
        description:
          "This channel coordinates the cross-functional launch: engineering, " <>
            "design, marketing, and support align here before the ship date. " <>
            "Owners are assigned per workstream; blockers are triaged daily at " <>
            "the standup and escalated to the launch captain when they slip. " <>
            "The current focus is the checklist freeze and the go/no-go review."
      },
      domain: AshUi.AshDomainFallback
    )
    |> Ash.create!()

    RowC
    |> Ash.Changeset.for_create(
      :create,
      %{conversation_id: conversation_id, topic: "ali", label: "alice"},
      domain: AshUi.AshDomainFallback
    )
    |> Ash.create!()

    # The connected mount registers the record's relationship subscriptions in
    # the MatchIndex keyed to THIS process — the seam through which an action's
    # own write notification echoes back as a dispatch-scoped reload path. The
    # disconnected path deliberately skips registration (no consumer process),
    # so the fixture takes the live path: a transport pid on the socket makes
    # `connected?/1` true, and a matching `$callers` entry lets the bridge's
    # `transport_pid/1` resolve the session pid (this process) without raising.
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

    socket
  end

  # The dispatch bindings, selected by the OWNING element's part attribute
  # (the composer toolbar now carries several other bindings, so document
  # order is no longer a stable selector): the composer poke button
  # (part="poke"), the send button (part="bench_send_button"), and the
  # mention-query button (part="set_mention_query").
  defp rendered_bindings(socket) do
    {html, _prints} = render_html(socket, nil)

    {
      binding_for_part(html, "poke"),
      binding_for_part(html, "bench_send_button"),
      binding_for_part(html, "set_mention_query")
    }
  end

  defp binding_for_part(html, part) do
    chunk =
      html
      |> String.split("<button")
      |> Enum.find(&String.contains?(&1, ~s(part="#{part}")))

    [_, key] = Regex.run(~r/ash_ui:dispatch:([A-Za-z0-9+\/=._-]+)"/, chunk)
    key
  end

  defp render_html(socket, prints) do
    {diff, prints, _socket} = render_diff(socket, prints)

    html =
      %{}
      |> Client.merge_diff(diff)
      |> Map.delete(:streams)
      |> Diff.to_iodata()
      |> IO.iodata_to_binary()

    {html, prints}
  end

  # One incremental render through the REAL render_shell path, against the
  # supplied LiveView fingerprints (nil = the initial full render). Returns the
  # wire diff, the updated fingerprints, and the socket with `ash_ui_changed`
  # cleared — mirroring the real bridge's `after_render` hook, so each dispatch's
  # changed set is isolated (the pending set is consumed once per render, never
  # accumulated across dispatches).
  defp render_diff(socket, prints) do
    rendered = AshUi.Phoenix.render_shell(socket.assigns)
    lv_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    {diff, prints, _components} =
      Diff.render(lv_socket, rendered, prints || Diff.new_fingerprints(), Diff.new_components())

    socket = put_in(socket.assigns[:ash_ui_changed], MapSet.new())
    {diff, prints, socket}
  end

  # Encoded wire-diff byte size — the exact JSON the server pushes to the
  # browser for this transition. This is the number the 5ms budget lives or
  # dies by; the `:s` (statics) key is included because LiveView only ships
  # statics for genuinely new fingerprints (initial render / new keyed rows).
  defp diff_bytes(diff), do: diff |> Jason.encode!() |> byte_size()

  defp dispatch!(socket, binding_key) do
    started = System.monotonic_time(:microsecond)

    {:noreply, socket} =
      AshUi.Phoenix.runtime_handle_event(
        "ash_ui:dispatch",
        %{"binding" => binding_key},
        socket
      )

    {socket, System.monotonic_time(:microsecond) - started}
  end

  # A keystroke's wire diff (an attribute-only change inside the composer each)
  # must be tiny: only the composer_text-reading attribute PAIRS and text slots
  # re-render — never the enclosing transcript rows, the conversation chrome,
  # the toolbar buttons' binding attributes, or the textarea's own binding/aria
  # attributes. Pre-fix stages of this blowup measured 7,000 bytes (unscoped
  # entry re-render) and 1,407 bytes (whole attrs chunk for one changed attr).
  @keystroke_diff_budget 512

  test "attribute-only dispatch inside an each ships a sub-1KB keystroke diff and reloads ZERO relationships" do
    socket = mount_page()

    {poke_key, _send_key, mention_key} = rendered_bindings(socket)

    # Initial full render establishes the client's fingerprints (the 24-row
    # transcript ships once, as on a real mount).
    {_full, prints, socket} = render_diff(socket, nil)

    # Warm the render/query/dispatch pipeline with a DIFFERENT genuine change
    # (mention_query), so the measured poke is a real ""->"poked" keystroke
    # against a warm, already-rendered page. Read counts are asserted on the
    # measured dispatch alone.
    {socket, _warm} = dispatch!(socket, mention_key)
    {_warm_diff, prints, socket} = render_diff(socket, prints)

    :ets.delete_all_objects(@counter_table)
    {socket, micros} = dispatch!(socket, poke_key)
    {diff, _prints, socket} = render_diff(socket, prints)
    bytes = diff_bytes(diff)

    assert socket.assigns.ash_ui_record.composer_text == "poked"
    assert socket.assigns[:ash_ui_errors] in [nil, []]

    IO.puts(
      "\n[latency-fixture] attribute-only (keystroke) dispatch: #{micros}µs, " <>
        "diff: #{bytes} bytes, reads: #{inspect(counts())}"
    )

    refute inspect(Map.drop(diff, [:s])) =~ "the quick brown fox",
           "a keystroke must not re-ship transcript row bodies: #{inspect(diff)}"

    # The toolbar buttons live INSIDE the composer box whose data-empty attr
    # reads composer_text, but they do not read it themselves: their long
    # binding-key attributes must not re-ship on a keystroke.
    refute inspect(Map.drop(diff, [:s])) =~ "Attach file",
           "composer toolbar buttons must not re-ship on a keystroke: #{inspect(diff)}"

    assert bytes < @keystroke_diff_budget,
           "an attribute-only keystroke diff must be < #{@keystroke_diff_budget} bytes, got #{bytes}: #{inspect(diff)}"

    assert counts() == %{row_a: 0, row_b: 0, row_c: 0},
           "an attribute-only dispatch must not reload any relationship, got #{inspect(counts())}"
  end

  test "a dispatch writing RowA reloads only the RowA relationships and ships a diff proportional to one row" do
    socket = mount_page()

    {poke_key, send_key, _mention_key} = rendered_bindings(socket)

    {_full, prints, socket} = render_diff(socket, nil)

    # Warm the pipeline with a genuine poke (""->"poked"); the measured send
    # then clears the composer and writes ONE RowA row.
    {socket, _warm} = dispatch!(socket, poke_key)
    {_warm_diff, prints, socket} = render_diff(socket, prints)

    :ets.delete_all_objects(@counter_table)
    {socket, micros} = dispatch!(socket, send_key)
    {diff, _prints, socket} = render_diff(socket, prints)
    bytes = diff_bytes(diff)

    assert socket.assigns[:ash_ui_errors] in [nil, []]

    # The new row's body must ship; the pre-existing transcript and the flat
    # conversation chrome must NOT.
    flat = inspect(Map.drop(diff, [:s]))
    assert flat =~ "sent message body", "the new message row must ship: #{inspect(diff)}"

    refute flat =~ "the quick brown fox",
           "existing transcript rows must not re-ship: #{inspect(diff)}"

    refute flat =~ "Design Review", "conversation chrome must not re-ship: #{inspect(diff)}"

    IO.puts(
      "\n[latency-fixture] related-write (send) dispatch: #{micros}µs, " <>
        "diff: #{bytes} bytes, reads: #{inspect(counts())}"
    )

    # One new row appears in the rows_a-backed lists; the pre-existing
    # transcript rows must not re-ship. The new row's statics ship once (new
    # keyed fingerprint), so the budget is a small multiple of one row, never
    # the whole 24-row transcript.
    assert bytes < 6 * @keystroke_diff_budget,
           "a one-row send diff must stay proportional to one row, got #{bytes}: #{inspect(diff)}"

    assert counter(:row_b) == 0,
           "a RowA write must not reload the RowB relationship, got #{inspect(counts())}"

    assert counter(:row_c) == 0,
           "a RowA write must not reload the mentions (RowC) relationship, got #{inspect(counts())}"

    assert counter(:row_a) == 1,
           "the RowA relationship must reload exactly once, got #{inspect(counts())}"
  end

  test "a dispatch changing a parent()-filtered attribute reloads only that relationship" do
    socket = mount_page()

    {poke_key, _send_key, mention_key} = rendered_bindings(socket)

    {_full, prints, socket} = render_diff(socket, nil)

    # Warm the pipeline with a genuine poke; the measured mention-query dispatch
    # is then a real ""->"ali" change against a warm page.
    {socket, _warm} = dispatch!(socket, poke_key)
    {_warm_diff, prints, socket} = render_diff(socket, prints)

    :ets.delete_all_objects(@counter_table)
    {socket, micros} = dispatch!(socket, mention_key)
    {diff, _prints, socket} = render_diff(socket, prints)
    bytes = diff_bytes(diff)

    assert socket.assigns.ash_ui_record.mention_query == "ali"
    assert socket.assigns[:ash_ui_errors] in [nil, []]

    IO.puts(
      "\n[latency-fixture] mention-query dispatch: #{micros}µs, " <>
        "diff: #{bytes} bytes, reads: #{inspect(counts())}"
    )

    assert bytes < 3 * @keystroke_diff_budget,
           "a mention-query diff must stay proportional to the mentions list, got #{bytes}: #{inspect(diff)}"

    # mention_query feeds ONLY the `mentions` relationship's parent() filter;
    # dependent_view_roots/2 must reload exactly that relationship and nothing
    # else — the conversation-keyed rows_a/rows_b did not become stale.
    assert counter(:row_c) == 1,
           "the parent()-dependent mentions relationship must reload exactly once, got #{inspect(counts())}"

    assert counter(:row_a) == 0 and counter(:row_b) == 0,
           "a mention_query change must not reload conversation-keyed relationships, got #{inspect(counts())}"
  end
end
