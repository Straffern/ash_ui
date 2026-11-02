defmodule AshUi.SafeHTML do
  @moduledoc false

  defstruct [:iodata]

  def new({:safe, iodata}), do: %__MODULE__{iodata: normalize(iodata)}
  def new(iodata), do: %__MODULE__{iodata: normalize(iodata)}

  defp normalize(value) when is_binary(value), do: value

  defp normalize(value) when is_list(value) or is_integer(value) do
    _size = :erlang.iolist_size(value)
    value
  rescue
    # broad rescue: SafeHTML coerces arbitrary iodata failures into a uniform ArgumentError.
    error ->
      raise ArgumentError,
            "invalid SafeHTML iodata #{inspect(value)}: #{Exception.message(error)}"
  end

  defp normalize(value) do
    to_string(value)
  rescue
    # broad rescue: SafeHTML coerces arbitrary stringification failures into a uniform ArgumentError.
    error ->
      raise ArgumentError,
            "invalid SafeHTML value #{inspect(value)}: #{Exception.message(error)}"
  end
end
