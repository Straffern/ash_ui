defmodule AshUi.Phoenix.LiveRender do
  @moduledoc """
  Transport shim: `AshUi.Render` emits the one render algebra
  (`AshUi.Rendered`/`AshUi.Comprehension`, LiveView-shape by
  contract); this module converts it — lazily, closure by closure — into
  the `Phoenix.LiveView.Rendered` structs LiveView's own diff engine
  consumes. No emission logic lives here.
  """

  alias AshUi.Patch.Compiler
  alias AshUi.Patch.Table
  alias AshUi.Phoenix.RenderTarget
  alias Phoenix.LiveView.Comprehension, as: LiveComprehension
  alias Phoenix.LiveView.Rendered, as: LiveRendered

  @doc """
  Build the root `Phoenix.LiveView.Rendered` for `record` from its
  resource's patch table. Same contract as `AshUi.Render.build/3`,
  pinned to the Phoenix render target.
  """
  @spec build(struct(), :all | MapSet.t(), keyword()) :: LiveRendered.t()
  def build(%resource{} = record, changed, opts \\ []) do
    table =
      case Keyword.get(opts, :table) do
        %Table{target: RenderTarget} = table ->
          table

        _other ->
          Compiler.table(resource, Keyword.get(opts, :view, :view), target: RenderTarget)
      end

    opts =
      opts
      |> Keyword.put(:table, table)
      |> Keyword.put(:target, RenderTarget)
      # the emitter constructs LiveView struct names directly: identical
      # field sets by frozen contract, zero conversion on the hot path
      |> Keyword.put(:rendered_module, LiveRendered)
      |> Keyword.put(:comprehension_module, LiveComprehension)

    record
    |> AshUi.Render.build(changed, opts)
  end

  @doc """
  Lazy conversion of the core render algebra into LiveView structs:
  dynamics stay closures, so the cost is O(invoked region) per render.
  Public so oracle tests can feed core-emitted structures through the
  native LiveView diff engine.
  """
  def to_live(%AshUi.Rendered{} = rendered) do
    %LiveRendered{
      static: rendered.static,
      dynamic: fn track_changes? ->
        rendered.dynamic.(track_changes?) |> Enum.map(&convert_dyn/1)
      end,
      fingerprint: rendered.fingerprint,
      root: rendered.root
    }
  end

  defp convert_dyn(%AshUi.Rendered{} = rendered), do: to_live(rendered)

  defp convert_dyn(%AshUi.Comprehension{} = comprehension) do
    %LiveComprehension{
      static: comprehension.static,
      has_key?: comprehension.has_key?,
      fingerprint: comprehension.fingerprint,
      stream: nil,
      entries:
        Enum.map(comprehension.entries, fn {key, vars, render} ->
          {key, vars,
           fn vars_changed, track_changes? ->
             render.(vars_changed, track_changes?) |> Enum.map(&convert_dyn/1)
           end}
        end)
    }
  end

  defp convert_dyn(other), do: other

  @doc false
  # A static and connected LiveView mount render the same handed-off session
  # snapshot. Materialize its pure render algebra once so the connected phase
  # can serialize the same result without rebuilding every keyed entry and
  # store-backed child. This is only valid for initial `:all` renders.
  def freeze(%LiveRendered{} = rendered) do
    dynamics = rendered.dynamic.(false) |> Enum.map(&freeze_dynamic/1)
    %{rendered | dynamic: fn _track_changes? -> dynamics end}
  end

  defp freeze_dynamic(%LiveRendered{} = rendered), do: freeze(rendered)

  defp freeze_dynamic(%LiveComprehension{} = comprehension) do
    entries =
      Enum.map(comprehension.entries, fn {key, vars, render} ->
        dynamics = render.(%{}, false) |> Enum.map(&freeze_dynamic/1)
        {key, vars, fn _vars_changed, _track_changes? -> dynamics end}
      end)

    %{comprehension | entries: entries}
  end

  defp freeze_dynamic(other), do: other
end
