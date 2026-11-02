defmodule AshUi.Phoenix.Errors do
  @moduledoc """
  Host-facing Phoenix `render_errors` view for AshUi error resources.

  Configure it on the host endpoint with:

      render_errors: [formats: [html: AshUi.Phoenix.Errors], layout: false]
  """

  def render(template, assigns) do
    otp_app = AshUi.Phoenix.otp_app(assigns)
    status_message = Phoenix.Controller.status_message_from_template(template)
    context = %{template: template, status_message: status_message, assigns: assigns}

    case AshUi.Phoenix.configured_resource(otp_app, :error_resource) do
      nil ->
        if String.ends_with?(template, ".json") do
          %{errors: %{detail: status_message}}
        else
          status_message
        end

      resource ->
        if String.ends_with?(template, ".json") do
          # exports died with the second model; JSON errors carry the
          # canonical status message
          %{errors: %{detail: status_message}}
        else
          AshUi.Phoenix.render_resource!(resource, context)
        end
    end
  end
end
