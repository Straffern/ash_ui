defmodule AshUi.Bench.Pages do
  @moduledoc false
  @row_count 1000
  @event_button_count 50
  def row_count do
    @row_count
  end

  def event_button_count do
    @event_button_count
  end

  def rows do
    Enum.map(1..@row_count, fn index ->
      %{
        id: "row-#{index}",
        label: "Row #{index}",
        summary: "Group #{rem(index - 1, 10)}",
        amount: index * 7
      }
    end)
  end

  def row_attrs do
    %{rows: rows(), selected_id: "none"}
  end

  def changed_row_payload do
    %{id: "row-500"}
  end

  def event_buttons do
    Enum.map(1..@event_button_count, fn index ->
      %{id: "event-#{index}", label: "Event #{index}", marker: "marker-#{index}"}
    end)
  end

  def events_attrs do
    %{buttons: event_buttons(), marker: "idle"}
  end

  def event_payload(iteration) when is_integer(iteration) and iteration > 0 do
    button_index = rem(iteration - 1, @event_button_count) + 1
    %{marker: "marker-#{button_index}:#{iteration}"}
  end

  def runtime_opts do
    []
  end

  defmodule BenchRow do
    @moduledoc false
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, public?: true)
      attribute(:label, :string, public?: true)
      attribute(:summary, :string, public?: true)
      attribute(:amount, :integer, public?: true)
    end

    calculations do
      # Display only — the select button lives in the OWNER view (RowsPage),
      # because :select_row is the page's action (nested_ui_model.md).
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:root, [data: [row_id: id]], [
            text(label),
            text(summary),
            text("score=" <> to_string(amount))
          ])
        )
      )
    end
  end

  defmodule RowsPage do
    @moduledoc false
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

    resource do
      short_name(:bench_rows_page)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:rows, {:array, :map}, allow_nil?: false, default: [])
      attribute(:selected_id, :string, allow_nil?: false, default: "none")
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      update(:select_row) do
        argument(:id, :string, allow_nil?: false)
        change(set_attribute(:selected_id, arg(:id)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:stack, [], [
            box(:row, [], [text("Selected:"), text(selected_id)]),
            each(rows, :row, [index: :row_index], [
              render(AshUi.Bench.Pages.BenchRow, %{
                id: row.id,
                label: row.label,
                summary: row.summary,
                amount: row.amount
              }),
              button(
                :action,
                [action_input: %{id: row.id}, type: :button, on_click: :select_row],
                [text("Select")]
              )
            ])
          ])
        )
      )
    end
  end

  defmodule EventsPage do
    @moduledoc false
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

    resource do
      short_name(:bench_events_page)
    end

    attributes do
      attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      attribute(:buttons, {:array, :map}, allow_nil?: false, default: [])
      attribute(:marker, :string, allow_nil?: false, default: "idle")
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      update(:mark) do
        argument(:marker, :string, allow_nil?: false)
        change(set_attribute(:marker, arg(:marker)))
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          box(:stack, [], [
            text(marker),
            each(buttons, :button, [index: :button_index], [
              button(
                :event_button,
                [
                  action_input: %{marker: button.marker},
                  type: :button,
                  data: [event_id: button.id, event_index: index(:button_index)],
                  on_click: :mark
                ],
                [text(button.label)]
              )
            ])
          ])
        )
      )
    end
  end
end
