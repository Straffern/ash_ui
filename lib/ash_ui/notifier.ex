defmodule AshUi.Notifier do
  @moduledoc """
  Ash notifier that forwards resource notifications into AshUi's
  notification-native read match index.
  """

  use Ash.Notifier

  # Atomic updates cannot supply original data; the match index treats a
  # missing before-image as "anything may have changed" and over-delivers.
  # Notifications are latency hints — reload is the correctness path — so
  # over-delivery is safe and domains keep their atomic updates.
  @impl true
  def requires_original_data?(_resource, _action), do: false

  @impl true
  def notify(%Ash.Notifier.Notification{} = notification) do
    AshUi.Notification.MatchIndex.dispatch(notification)
    :ok
  end
end
