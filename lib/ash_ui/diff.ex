defmodule AshUi.Diff do
  @moduledoc """
  The differential kernel over `AshUi.Rendered`: produces
  LiveView-wire-compatible diff maps and retained fingerprint state.

  This is a copied, minimal subset of `Phoenix.LiveView.Diff`
  (phoenix_live_view 1.1.32, MIT © Chris McCord — see NOTICE below),
  reduced to what the AshUi render algebra emits:

    * static sharing via fingerprints (`:s`, template table `:p`)
    * nil-based change tracking (nil dynamic = unchanged)
    * recursive rendered children with branch fingerprint replacement
    * keyed comprehension insertion, movement, removal, and update (`:k`,
      count `:kc`, moved entries as `[previous_index, diff]`)
    * duplicate-key rejection

  LiveComponents and streams are NOT implemented: the AshUi model has
  no component concept and renders collections as keyed comprehensions
  over resource state, so those branches are excluded by design. Do not
  extend this module's surface — wire-protocol compatibility is asserted
  against LiveView as a pinned, test-only executable oracle.

  Diff-map keys are a FROZEN wire protocol shared with the LiveView
  client: `:s` statics/template-ref, `:r` root, `:k` keyed entries,
  `:kc` keyed count, `:p` shared template table.

  NOTICE: Portions derived from phoenix_live_view
  (https://github.com/phoenixframework/phoenix_live_view), MIT license.
  """

  alias AshUi.{Comprehension, Rendered}

  @static :s
  @keyed :k
  @keyed_count :kc
  @template :p

  @doc "Fresh fingerprint state for a new session."
  def new_fingerprints, do: {nil, %{}}

  @doc """
  Diffs `rendered` against the retained `prints`, returning
  `{diff_map, new_prints}`. A root fingerprint mismatch resets state and
  re-renders fully, exactly like LiveView.
  """
  def render(%Rendered{fingerprint: actual} = rendered, {expected, _})
      when expected != nil and expected != actual do
    render(rendered, new_fingerprints())
  end

  def render(%Rendered{} = rendered, prints) do
    {diff, prints, template} = traverse(rendered, prints, {%{}, %{}}, true)
    {maybe_add_template(diff, template), prints}
  end

  ## Traversal — clause-for-clause with the oracle, minus components/streams.

  defp traverse(
         %Rendered{fingerprint: fingerprint} = rendered,
         {fingerprint, children},
         template,
         changed?
       ) do
    {_counter, diff, children, template} =
      traverse_dynamic(rendered.dynamic.(changed?), children, template, changed?)

    {diff, {fingerprint, children}, template}
  end

  defp traverse(
         %Rendered{fingerprint: fingerprint, static: static} = rendered,
         _mismatch,
         template,
         changed?
       ) do
    {_counter, diff, children, template} =
      traverse_dynamic(rendered.dynamic.(false), %{}, template, changed?)

    diff = if rendered.root, do: Map.put(diff, :r, 1), else: diff
    {diff, template} = maybe_share_template(diff, fingerprint, static, template)
    {diff, {fingerprint, children}, template}
  end

  defp traverse(
         %Comprehension{fingerprint: fingerprint, entries: entries, has_key?: has_key?},
         {fingerprint, previous_prints},
         template,
         changed?
       ) do
    if template do
      {keyed, keyed_prints, template} =
        traverse_keyed(entries, previous_prints, template, changed?, has_key?)

      {maybe_add_keyed(%{}, keyed), {fingerprint, keyed_prints}, template}
    else
      {keyed, keyed_prints, template} =
        traverse_keyed(entries, previous_prints, {%{}, %{}}, changed?, has_key?)

      diff = %{} |> maybe_add_keyed(keyed) |> maybe_add_template(template)
      {diff, {fingerprint, keyed_prints}, nil}
    end
  end

  defp traverse(%Comprehension{entries: []}, _mismatch, template, _changed?) do
    # never rendered and empty: skip entirely (streams would forbid this,
    # and this algebra has no streams)
    {"", nil, template}
  end

  defp traverse(
         %Comprehension{
           static: static,
           fingerprint: fingerprint,
           entries: entries,
           has_key?: has_key?
         },
         _mismatch,
         template,
         changed?
       ) do
    if template do
      {keyed, keyed_prints, template} = traverse_keyed(entries, %{}, template, changed?, has_key?)

      {diff, template} = maybe_share_template(%{@keyed => keyed}, fingerprint, static, template)

      {diff, {fingerprint, keyed_prints}, template}
    else
      {keyed, keyed_prints, template} =
        traverse_keyed(entries, %{}, {%{}, %{}}, changed?, has_key?)

      diff = %{@static => static, @keyed => keyed} |> maybe_add_template(template)
      {diff, {fingerprint, keyed_prints}, nil}
    end
  end

  defp traverse(nil, fingerprint_tree, template, _changed?) do
    {nil, fingerprint_tree, template}
  end

  defp traverse(iodata, _mismatch, template, _changed?) do
    {IO.iodata_to_binary(iodata), nil, template}
  end

  defp traverse_dynamic(dynamic, children, template, changed?) do
    traverse_dynamic(dynamic, 0, %{}, children, template, changed?)
  end

  defp traverse_dynamic([entry | entries], counter, diff, children, template, changed?)
       when is_nil(entry) or (is_binary(entry) and not is_map_key(children, counter)) do
    traverse_dynamic(
      entries,
      counter + 1,
      if(is_binary(entry), do: Map.put(diff, counter, entry), else: diff),
      children,
      template,
      changed?
    )
  end

  defp traverse_dynamic([entry | entries], counter, diff, children, template, changed?) do
    child = Map.get(children, counter)

    {serialized, child_fingerprint, template} = traverse(entry, child, template, changed?)

    # nil means no changes; an empty map is an unchanged rendered struct —
    # neither is emitted
    diff =
      if serialized != nil and serialized != %{} do
        Map.put(diff, counter, serialized)
      else
        diff
      end

    children =
      cond do
        child_fingerprint -> Map.put(children, counter, child_fingerprint)
        child -> Map.delete(children, counter)
        true -> children
      end

    traverse_dynamic(entries, counter + 1, diff, children, template, changed?)
  end

  defp traverse_dynamic([], counter, diff, children, template, _changed?) do
    {counter, diff, children, template}
  end

  defp traverse_keyed(entries, previous_prints, template, changed?, has_key?) do
    {{diff, count, new_prints, template}, _seen_keys} =
      Enum.reduce(entries, {{%{}, 0, %{}, template}, %{}}, fn
        {key, vars, render}, {{_diff, index, _new_prints, _template} = acc, seen_keys} ->
          {key, seen_keys} =
            cond do
              not has_key? ->
                {index, seen_keys}

              Map.has_key?(seen_keys, key) ->
                raise "found duplicate key #{inspect(key)} in comprehension"

              true ->
                {key, Map.put(seen_keys, key, true)}
            end

          {process_keyed({key, vars, render}, previous_prints, changed?, acc), seen_keys}
      end)

    # nothing changed and nothing was added or removed: no diff at all
    if diff == %{} and count > 0 and count == map_size(previous_prints) do
      {nil, new_prints, template}
    else
      {Map.put(diff, @keyed_count, count), new_prints, template}
    end
  end

  # existing entry under change tracking
  defp process_keyed({key, new_vars, render}, previous_prints, true, acc)
       when is_map_key(previous_prints, key) do
    {diff, index, new_prints, template} = acc

    %{vars: previous_vars, index: previous_index, child_prints: child_prints} =
      Map.fetch!(previous_prints, key)

    vars_changed = changed_vars(previous_vars, new_vars)

    {_counter, child_diff, child_prints, template} =
      traverse_dynamic(render.(vars_changed, true), child_prints, template, true)

    new_prints =
      Map.put(new_prints, key, %{index: index, vars: new_vars, child_prints: child_prints})

    if child_diff == %{} or child_diff == nil do
      # unchanged content: annotate a pure move with the previous index
      diff = if previous_index != index, do: Map.put(diff, index, previous_index), else: diff
      {diff, index + 1, new_prints, template}
    else
      child_diff = if previous_index != index, do: [previous_index, child_diff], else: child_diff
      {Map.put(diff, index, child_diff), index + 1, new_prints, template}
    end
  end

  # new entry: full render with change tracking disabled
  defp process_keyed({key, vars, render}, _previous_prints, _changed?, acc) do
    {diff, index, new_prints, template} = acc

    {_counter, child_diff, child_prints, template} =
      traverse_dynamic(render.(%{}, false), %{}, template, false)

    new_prints =
      Map.put(new_prints, key, %{index: index, vars: vars, child_prints: child_prints})

    {Map.put(diff, index, child_diff), index + 1, new_prints, template}
  end

  # LiveView computes per-entry changed vars through Phoenix.Component.assign;
  # the observable contract is just "keys whose values differ"
  defp changed_vars(previous_vars, new_vars) do
    Enum.reduce(new_vars, %{}, fn {key, value}, changed ->
      case previous_vars do
        %{^key => ^value} -> changed
        %{^key => previous} -> Map.put(changed, key, {:changed, previous, value})
        _missing -> Map.put(changed, key, true)
      end
    end)
  end

  defp maybe_share_template(map, fingerprint, static, {print_to_pos, pos_to_static}) do
    case print_to_pos do
      %{^fingerprint => pos} ->
        {Map.put(map, @static, pos), {print_to_pos, pos_to_static}}

      %{} ->
        pos = map_size(pos_to_static)
        pos_to_static = Map.put(pos_to_static, pos, static)
        print_to_pos = Map.put(print_to_pos, fingerprint, pos)
        {Map.put(map, @static, pos), {print_to_pos, pos_to_static}}
    end
  end

  defp maybe_share_template(map, _fingerprint, static, nil) do
    {Map.put(map, @static, static), nil}
  end

  defp maybe_add_template(map, {_, template}) when template != %{},
    do: Map.put(map, @template, template)

  defp maybe_add_template(map, _new_template), do: map

  defp maybe_add_keyed(diff, nil), do: diff
  defp maybe_add_keyed(diff, keyed), do: Map.put(diff, @keyed, keyed)
end
