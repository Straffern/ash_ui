defmodule AshUi.Phoenix.DispatchErrorsTest do
  @moduledoc """
  DESIGN §5 completion: a failed action's Ash error class rides the patch
  cycle. Field-path'd errors distribute to field-name-bound elements
  (aria-invalid + message, ARIA-first, neutral vocabulary); the rest is
  page error state. Errors are per-dispatch transients: the next
  successful dispatch clears them through exactly the same slots.
  """
  use ExUnit.Case, async: false

  alias AshUi.Patch.Compiler
  alias AshUi.Phoenix, as: Bridge

  defmodule FormPage do
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
      attribute(:name, :string, allow_nil?: false, default: "", public?: true)
      attribute(:note, :string, allow_nil?: false, default: "", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read])

      update :save do
        require_atomic?(false)

        argument :name, :string do
          allow_nil?(false)
          constraints(min_length: 3)
        end

        change(set_attribute(:name, arg(:name)))
      end

      update :set_note do
        require_atomic?(false)
        argument(:note, :string, allow_nil?: false)
        change(set_attribute(:note, arg(:note)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:root, [], [
            input(
              :name_input,
              [value: name, on_input: :save, action_input: %{name: event(:value)}],
              []
            ),
            box(:errors_box, [], [text(field_errors(:name))]),
            input(
              :note_input,
              [value: note, on_input: :set_note, action_input: %{note: event(:value)}],
              []
            ),
            input(
              :nested_name_input,
              [
                name: "track_123_name",
                value: name,
                on_input: :save,
                action_input: %{name: event(:value)}
              ],
              []
            ),
            input(
              :external_name_input,
              [
                name: "user[name]",
                value: name,
                on_input: :save,
                action_input: %{name: event(:value)}
              ],
              []
            )
          ])
        )
      )
    end
  end

  defp seed do
    Ash.Seed.seed!(FormPage, %{session_id: Ash.UUID.generate()})
  end

  defp semantic_html(record, opts) do
    {:ok, tree} =
      AshUi.Runtime.Rendering.render_tree(
        AshUi.Runtime.ResourceInfo.compiled_resource(FormPage),
        record,
        %{},
        opts
      )

    {:safe, iodata} =
      AshUi.RenderTarget.Html.render_static(tree,
        target: AshUi.RenderTarget.Static
      )

    IO.iodata_to_binary(iodata)
  end

  test "the compiler indexes error slots: bound attr chunks + authored field_errors reads" do
    table = Compiler.table(FormPage)

    assert length(table.error_slots) >= 3,
           "expected both bound inputs' attr chunks and the field_errors text slot: #{inspect(table.error_slots)}"

    text_slots = for {_id, %{kind: :text} = slot} <- table.slots, slot.errors?, do: slot
    assert [_field_errors_slot] = text_slots
  end

  test "field-path'd errors distribute to the bound element; unbound fields stay clean" do
    record = seed()

    errors = [
      %Ash.Error.Changes.InvalidArgument{
        field: :name,
        message: "length must be at least %{min}",
        vars: [min: 3]
      }
    ]

    html = semantic_html(record, errors: errors)

    assert html =~ ~r/<input[^>]*aria-invalid="true"[^>]*>/
    assert html =~ ~s(data-ash-ui-error="length must be at least 3")
    assert html =~ "length must be at least 3</"

    # the note input is bound to a DIFFERENT field — it stays clean
    refute Regex.match?(~r/note[^>]*aria-invalid/, html)

    # a nested/local control may use a :name action argument without being
    # the form's top-level `name` field.
    refute Regex.match?(~r/track_123_name[^>]*aria-invalid/, html)

    # errorless render is byte-stable (no error vocabulary at rest)
    clean = semantic_html(record, errors: [])
    refute clean =~ "aria-invalid"
    refute clean =~ "data-ash-ui-error"

    required =
      struct(Ash.Error.Changes.Required,
        field: :name,
        type: :attribute,
        resource: FormPage,
        bread_crumbs: [
          "Error returned from: FormPage.save",
          "Error returned from: NestedResource.create"
        ]
      )

    required_html = semantic_html(record, errors: [required])
    assert required_html =~ ~s(data-ash-ui-error="is required")
    assert required_html =~ "is required</"
    refute required_html =~ "Error returned from"
  end

  test "a failed dispatch assigns the error class and re-renders exactly the error slots" do
    record = seed()
    table = Compiler.table(FormPage, :view, target: AshUi.Phoenix.RenderTarget)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        ash_ui_record: record,
        ash_ui_resource: FormPage,
        ash_ui_view: :view,
        ash_ui_tables: %{{FormPage, :view, AshUi.Phoenix.RenderTarget} => table},
        ash_ui_params: %{},
        ash_ui_session_id: record.session_id,
        ash_ui_actor: nil,
        ash_ui_location: "/form"
      }
    }

    key =
      table.event_elements
      |> Map.keys()
      |> Enum.find(&String.contains?(&1, "/0"))
      |> Compiler.addr_component()

    {:noreply, failed} =
      Bridge.runtime_handle_event(
        "ash_ui:dispatch:" <> key <> ".input",
        %{"value" => "x"},
        socket
      )

    assert [%{field: :name} | _] = failed.assigns.ash_ui_errors

    error_addrs = MapSet.new(table.error_slots)
    assert failed.assigns.ash_ui_changed == error_addrs

    # a successful dispatch clears the transients through the same slots
    {:noreply, cleared} =
      Bridge.runtime_handle_event(
        "ash_ui:dispatch:" <> key <> ".input",
        %{"value" => "long enough"},
        failed
      )

    assert cleared.assigns.ash_ui_errors == []

    assert MapSet.subset?(error_addrs, cleared.assigns.ash_ui_changed),
           "clearing must re-render the error slots"
  end

  test "a nested external form target supplies only its scalar leaf to event(:value)" do
    record = seed()
    table = Compiler.table(FormPage, :view, target: AshUi.Phoenix.RenderTarget)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        ash_ui_record: record,
        ash_ui_resource: FormPage,
        ash_ui_view: :view,
        ash_ui_tables: %{{FormPage, :view, AshUi.Phoenix.RenderTarget} => table},
        ash_ui_params: %{},
        ash_ui_session_id: record.session_id,
        ash_ui_actor: nil,
        ash_ui_location: "/form"
      }
    }

    key = Compiler.addr_component("v/4")

    {:noreply, nested} =
      Bridge.runtime_handle_event(
        "ash_ui:dispatch:" <> key <> ".input",
        %{
          "_target" => ["user", "name"],
          "user" => %{"name" => "nested value"}
        },
        socket
      )

    assert nested.assigns.ash_ui_record.name == "nested value"
    assert nested.assigns[:ash_ui_errors] in [nil, []]

    {:noreply, flat} =
      Bridge.runtime_handle_event(
        "ash_ui:dispatch:" <> key <> ".input",
        %{"_target" => ["name"], "name" => "flat value"},
        nested
      )

    assert flat.assigns.ash_ui_record.name == "flat value"
    assert flat.assigns[:ash_ui_errors] in [nil, []]
  end
end
