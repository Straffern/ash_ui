defmodule AshUi.Verifiers.Helpers do
  @moduledoc false

  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  def module!(dsl) do
    Verifier.get_persisted(dsl, :module)
  end

  def compiled_resource!(dsl) do
    case Verifier.get_persisted(dsl, :ash_ui_compiled_resource) do
      nil ->
        raise ArgumentError,
              "expected :ash_ui_compiled_resource to be persisted before verification"

      resource ->
        resource
    end
  end

  def dsl_error(dsl, path, message) do
    DslError.exception(
      module: module!(dsl),
      path: List.wrap(path),
      message: message
    )
  end

  def defer(dsl, path, message) do
    {:defer,
     %{
       reason: :module_not_loaded,
       module: module!(dsl),
       path: List.wrap(path),
       message: message
     }}
  end

  def verify_each(enum, fun) do
    Enum.reduce_while(enum, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
        {:defer, _deferred} = deferred -> {:halt, deferred}
      end
    end)
  end

  def collect_each(enum, fun) do
    Enum.reduce_while(enum, {:ok, []}, fn item, {:ok, deferred_acc} ->
      case fun.(item) do
        :ok -> {:cont, {:ok, deferred_acc}}
        {:defer, deferred} -> {:cont, {:ok, [deferred | deferred_acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, deferred} -> {:ok, Enum.reverse(deferred)}
      other -> other
    end
  end

  def merge_deferred(:ok, deferred), do: {:ok, deferred}
  def merge_deferred({:ok, next}, deferred), do: {:ok, deferred ++ next}
  def merge_deferred({:error, _error} = error, _deferred), do: error
  def merge_deferred({:defer, next}, deferred), do: {:ok, deferred ++ [next]}

  def verifier_result({:ok, []}), do: :ok
  def verifier_result({:ok, deferred}), do: {:ok, deferred}
  def verifier_result(other), do: other
end
