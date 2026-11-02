defmodule AshUi.Runtime.Errors do
  @moduledoc false

  alias AshUi.Expressions.Formatters

  # The renderer receives the ORIGINAL Ash action error objects. These helpers
  # only project that standard error surface into field/message values; they do
  # not copy errors into an AshUi-owned struct or persistence channel.
  def list(%{errors: errors}) when is_list(errors), do: errors
  def list(errors) when is_list(errors), do: errors
  def list(error), do: [error]

  def field_errors(errors, field) do
    errors
    |> List.wrap()
    |> Enum.filter(&(field(&1) == field))
    |> Enum.map(&message/1)
  end

  def field(%{field: field}), do: field
  def field(_error), do: nil

  def message(%{message: message, vars: vars}) when is_binary(message) do
    vars
    |> List.wrap()
    |> Enum.reduce(message, fn {key, value}, rendered ->
      String.replace(rendered, "%{#{key}}", Formatters.render_string(value))
    end)
    |> strip_framework_noise()
  end

  def message(%{message: message}) when is_binary(message),
    do: strip_framework_noise(message)

  def message(%{__exception__: true, bread_crumbs: _bread_crumbs} = error) do
    error
    |> Map.put(:bread_crumbs, [])
    |> Exception.message()
    |> strip_framework_noise()
  end

  def message(%{__exception__: true} = error),
    do: error |> Exception.message() |> strip_framework_noise()

  def message(error) when is_binary(error), do: strip_framework_noise(error)
  def message(error), do: inspect(error)

  defp strip_framework_noise(message) do
    message
    |> String.replace(~r/^Bread Crumbs:[\s\S]*?Error returned from: \S+\s+/u, "")
    |> String.replace(~r/^attribute \S+\s+/u, "")
    |> String.trim()
  end

  def normalize_runtime_reason(reason) do
    case extract_runtime_reason(reason) do
      nil -> reason
      extracted -> extracted
    end
  end

  def normalize_invoke_error(error) do
    Ash.Error.to_error_class(error)
  rescue
    # broad rescue: Ash.Error accepts only Ash/error-shaped terms; leave foreign exceptions intact.
    _other -> error
  end

  def extract_runtime_reason(%{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &extract_runtime_reason/1)
  end

  def extract_runtime_reason(forbidden_read: read_name) when is_atom(read_name) do
    {:forbidden_read, read_name}
  end

  def extract_runtime_reason(errors) when is_list(errors) do
    Enum.find_value(errors, &extract_runtime_reason/1)
  end

  def extract_runtime_reason(%{value: value}) do
    extract_runtime_reason(value)
  end

  def extract_runtime_reason(_other) do
    nil
  end
end
