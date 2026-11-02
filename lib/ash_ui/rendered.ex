defmodule AshUi.Rendered do
  @moduledoc """
  The render algebra's node: statics interleaved with a dynamic function,
  identified by a fingerprint. Structurally identical to
  `Phoenix.LiveView.Rendered` (phoenix_live_view 1.1.x) so transport
  adapters can convert by struct rename alone; the shape is a frozen
  contract verified against LiveView as an executable oracle.

  `dynamic.(track_changes?)` returns one entry per dynamic slot:
  `nil` (unchanged), iodata, a nested `AshUi.Rendered`, or an
  `AshUi.Comprehension`.
  """

  defstruct [:static, :dynamic, :fingerprint, :root, caller: :not_available]

  @type dyn :: nil | iodata() | t() | AshUi.Comprehension.t()

  @type t :: %__MODULE__{
          static: [binary()],
          dynamic: (boolean() -> [dyn()]),
          fingerprint: integer(),
          root: boolean() | nil,
          caller:
            :not_available | {module(), {atom(), non_neg_integer()}, String.t(), pos_integer()}
        }
end

defmodule AshUi.Comprehension do
  @moduledoc """
  A keyed collection in the render algebra — structurally identical to
  `Phoenix.LiveView.Comprehension`. AshUi always emits keyed entries
  (`has_key?: true`) and never emits streams: collections are keyed
  comprehensions over resource state by model, permanently — `stream` and
  LiveComponents are excluded from this algebra by design, not omission.

  Entries are `{key, vars, render_fun}` where `render_fun.(changed_vars,
  track_changes?)` returns the entry's dynamic list.
  """

  defstruct [:static, :entries, :fingerprint, stream: nil, has_key?: true]

  @type key :: term()
  @type keyed_render_fun :: (map(), boolean() -> [AshUi.Rendered.dyn()])

  @type t :: %__MODULE__{
          static: [binary()],
          entries: [{key(), map(), keyed_render_fun()}],
          fingerprint: integer(),
          stream: nil,
          has_key?: boolean()
        }
end

defmodule AshUi.Rendered.Materialize do
  @moduledoc """
  Materializes a rendered structure to iodata — the SAME statics and
  dynamics the differential engine diffs, zipped without change tracking.
  Transports use this for full-document bodies so materialization and
  diffing can never disagree.
  """

  alias AshUi.{Comprehension, Rendered}

  @spec to_iodata(Rendered.t() | Comprehension.t() | iodata() | nil) :: iodata()
  def to_iodata(%Rendered{static: static, dynamic: dynamic}) do
    zip(static, Enum.map(dynamic.(false), &to_iodata/1))
  end

  def to_iodata(%Comprehension{static: static, entries: entries}) do
    Enum.map(entries, fn {_key, _vars, render} ->
      zip(static, Enum.map(render.(%{}, false), &to_iodata/1))
    end)
  end

  def to_iodata(nil), do: []
  def to_iodata(iodata), do: iodata

  defp zip([static | statics], dynamics) do
    [static | Enum.flat_map(Enum.zip(dynamics, statics), fn {d, s} -> [d, s] end)]
  end
end
