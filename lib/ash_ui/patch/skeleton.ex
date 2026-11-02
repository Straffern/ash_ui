defmodule AshUi.Patch.Skeleton do
  @moduledoc """
  Target-specific static skeleton compiled from a resource's lowered view:
  interleaved static markup + ordered dynamic refs, the exact
  statics/dynamics contract the host bridge's `Rendered` structs consume.

  Compilation renders the view ONCE through the ordinary render pipeline
  (`ViewRender` → `RenderTree.render` → `RenderTarget.Html`) with unique
  alphanumeric sentinels substituted at every dynamic position, then splits
  the produced HTML on those sentinels. Statics are therefore byte-aligned
  with the full renderer by construction — themes, parts, aria, event
  bindings and attribute ordering all come from the same code path. The
  compiled skeleton is pure data + evaluator closures; the runtime render
  path never materializes a tree.

  Dynamic refs (document order):

      {:text, addr, eval}                 — escaped text position
      {:attr_pair, addr, name, eval}      — whole ` name="value"` pair
      {:attr_value, addr, name, eval}     — value embedded in a merged attr
      {:branch, addr, cond_eval, arms}    — arms: %{true: skel|nil, false: skel|nil}
      {:keyed, addr, items_eval, item}    — item: %{skeleton, as, index}
      {:child, addr, resource}            — nested render(Resource, input)

  `addr` is the SAME lowered address the patch table assigns its slots, so
  the changed-address set from
  `AshUi.Patch.Runtime.changed_addresses/3` gates re-emission
  directly.
  """

  alias AshUi.Expr.Compiled, as: CompiledExpr
  alias AshUi.Patch.Evaluator

  defstruct statics: [], dynamics: [], fingerprint: nil, root?: false

  @type dyn ::
          {:text, String.t(), (term() -> term())}
          | {:attr_pair, String.t(), String.t(), (term() -> term())}
          | {:attr_value, String.t(), String.t(), (term() -> term())}
          | {:branch, String.t(), (term() -> term()), %{true: t() | nil, false: t() | nil}}
          | {:keyed, String.t(), (term() -> term()), map()}
          | {:child, String.t(), module()}

  @type t :: %__MODULE__{statics: [binary()], dynamics: [dyn()], fingerprint: term()}

  @doc """
  Compile the skeleton for a lowered view node of `resource`. `base`
  addresses the subtree: arm and item skeletons compile under their REAL
  address prefix (`addr/t`, `addr/f`, `addr/*`) so element addresses are
  unique across the whole table — binding keys depend on it.
  """
  @spec compile(module(), map() | nil, keyword()) :: t()
  def compile(resource, lowered, opts \\ [])

  def compile(_resource, nil, _opts),
    do: %__MODULE__{statics: [""], dynamics: [], fingerprint: 0}

  def compile(resource, lowered, opts) do
    base = Keyword.get(opts, :base, "v")
    target = Keyword.get(opts, :target, AshUi.RenderTarget.Static)
    static_chain = Keyword.get(opts, :static_chain, [])
    dynamic_chain? = Keyword.get(opts, :dynamic_chain?, false)

    lowered =
      if dynamic_chain? and runtime_chain_attrs?(target),
        do: mark_runtime_attrs(lowered),
        else: lowered

    lowered = annotate_parser_dynamic_text(lowered, resource, %{})
    parser_dynamic_text? = parser_dynamic_text_at_level?(lowered)
    {transformed, refs} = transform(lowered, base, %{}, resource, target)
    html = sentinel_html(resource, transformed, target, static_chain, base)

    split(
      html,
      refs,
      resource,
      target,
      static_chain,
      dynamic_chain?,
      parser_dynamic_text?
    )
  end

  # Runtime ids mark exactly the PATCH-ADDRESSABLE elements
  # (Compiler.patch_addressable?/1 — the named compile-time property) plus
  # template/arm roots, which are addressable by position.
  defp mark_runtime_attrs(nodes), do: mark_runtime_roots(nodes)

  defp mark_runtime_roots(nodes) when is_list(nodes),
    do: Enum.map(nodes, &mark_runtime_node(&1, true))

  defp mark_runtime_roots(node), do: mark_runtime_node(node, true)

  defp mark_runtime_node(%{kind: :element} = node, root?) do
    node =
      Map.update(node, :children, [], fn children ->
        Enum.map(children, &mark_runtime_node(&1, false))
      end)

    cond do
      authored_id?(Map.get(node, :attrs, %{})) ->
        node

      root? or AshUi.Patch.Compiler.patch_addressable?(node) ->
        Map.put(node, :__bp_runtime_attrs__, true)

      true ->
        node
    end
  end

  defp mark_runtime_node(%{kind: _kind} = node, _root?) do
    Enum.reduce([:children, :child, :then, :else], node, fn key, node ->
      if Map.has_key?(node, key),
        do: Map.update!(node, key, &mark_runtime_roots/1),
        else: node
    end)
  end

  defp mark_runtime_node(other, _root?), do: other

  defp runtime_chain_attrs?(target) do
    (function_exported?(target, :runtime_chain_attrs?, 0) or
       (Code.ensure_loaded?(target) and function_exported?(target, :runtime_chain_attrs?, 0))) and
      target.runtime_chain_attrs?()
  end

  # Dynamic text is usually scalar text, but a typed SafeHTML/opaque value can
  # expand to block markup. Carry that Ash type fact through nested each
  # bindings so only the owning subtree opts out of browser root skipping.
  defp annotate_parser_dynamic_text(nodes, resource, item_schemas) when is_list(nodes) do
    Enum.map(nodes, &annotate_parser_dynamic_text(&1, resource, item_schemas))
  end

  defp annotate_parser_dynamic_text(
         %{kind: :text, content: %CompiledExpr{} = expr} = node,
         resource,
         item_schemas
       ) do
    if parser_dynamic_expr?(expr, resource, item_schemas),
      do: Map.put(node, :__bp_parser_dynamic_text__, true),
      else: node
  end

  defp annotate_parser_dynamic_text(
         %{kind: :each} = node,
         resource,
         item_schemas
       ) do
    item_schemas =
      case expr_schema(Map.get(node, :items), resource, item_schemas) do
        {:array, item_schema} -> Map.put(item_schemas, node.as, item_schema)
        _unknown -> item_schemas
      end

    Map.update(node, :child, nil, &annotate_parser_dynamic_text(&1, resource, item_schemas))
  end

  defp annotate_parser_dynamic_text(%{kind: :resource_component} = node, _resource, _schemas),
    do: node

  defp annotate_parser_dynamic_text(%{kind: _kind} = node, resource, item_schemas) do
    Enum.reduce([:children, :child, :then, :else], node, fn key, node ->
      if Map.has_key?(node, key) do
        Map.update!(node, key, &annotate_parser_dynamic_text(&1, resource, item_schemas))
      else
        node
      end
    end)
  end

  defp annotate_parser_dynamic_text(other, _resource, _item_schemas), do: other

  defp parser_dynamic_text_at_level?(nodes) when is_list(nodes),
    do: Enum.any?(nodes, &parser_dynamic_text_at_level?/1)

  defp parser_dynamic_text_at_level?(%{kind: :text} = node),
    do: Map.get(node, :__bp_parser_dynamic_text__, false)

  # A comprehension has no independent DOM root around its output. Its owning
  # skeleton must therefore inherit parser-dynamic risk from the item template.
  defp parser_dynamic_text_at_level?(%{kind: :each, child: child}),
    do: parser_dynamic_text_anywhere?(child)

  defp parser_dynamic_text_at_level?(%{kind: kind})
       when kind in [:if, :when, :resource_component, :computed],
       do: false

  defp parser_dynamic_text_at_level?(%{kind: _kind} = node) do
    Enum.any?([:children, :child, :then, :else], fn key ->
      Map.has_key?(node, key) and parser_dynamic_text_at_level?(Map.get(node, key))
    end)
  end

  defp parser_dynamic_text_at_level?(_other), do: false

  defp parser_dynamic_text_anywhere?(nodes) when is_list(nodes),
    do: Enum.any?(nodes, &parser_dynamic_text_anywhere?/1)

  defp parser_dynamic_text_anywhere?(%{kind: :text} = node),
    do: Map.get(node, :__bp_parser_dynamic_text__, false)

  defp parser_dynamic_text_anywhere?(%{kind: _kind} = node) do
    Enum.any?([:children, :child, :then, :else], fn key ->
      Map.has_key?(node, key) and parser_dynamic_text_anywhere?(Map.get(node, key))
    end)
  end

  defp parser_dynamic_text_anywhere?(_other), do: false

  defp parser_dynamic_expr?(expr, resource, item_schemas) do
    case expr_schema(expr, resource, item_schemas) do
      {:type, type, constraints} -> parser_dynamic_type?(type, constraints)
      _unknown -> false
    end
  end

  defp expr_schema(%CompiledExpr{ir: {:_ref, [], field}}, resource, _item_schemas)
       when is_atom(field) do
    schema_path({:resource, resource}, [field])
  end

  defp expr_schema(%CompiledExpr{ir: {:_item, binding, path}}, _resource, item_schemas)
       when is_atom(binding) and is_list(path) do
    case Map.fetch(item_schemas, binding) do
      {:ok, schema} -> schema_path(schema, path)
      :error -> nil
    end
  end

  defp expr_schema(_expr, _resource, _item_schemas), do: nil

  defp schema_path(schema, []), do: schema

  defp schema_path(schema, [field | rest]) when is_atom(field) do
    case schema_field(schema, field) do
      nil -> nil
      field_schema -> schema_path(field_schema, rest)
    end
  end

  defp schema_field({:resource, resource}, field) do
    case Ash.Resource.Info.field(resource, field) do
      %{destination: destination, cardinality: :many} when is_atom(destination) ->
        {:array, {:resource, destination}}

      %{destination: destination} when is_atom(destination) ->
        {:resource, destination}

      %{type: type, constraints: constraints} ->
        type_schema(type, constraints || [])

      _unknown ->
        nil
    end
  rescue
    _error in [ArgumentError, UndefinedFunctionError] -> nil
  end

  defp schema_field({:type, type, constraints}, field) do
    case normalized_type_schema(type, constraints) do
      {:type, Ash.Type.Map, constraints} ->
        constraints
        |> Keyword.get(:fields, [])
        |> Keyword.get(field)
        |> case do
          nil ->
            nil

          field_constraints ->
            type_schema(
              Keyword.fetch!(field_constraints, :type),
              Keyword.get(field_constraints, :constraints, [])
            )
        end

      _not_a_map ->
        nil
    end
  end

  defp schema_field(_schema, _field), do: nil

  defp type_schema({:array, type}, constraints) do
    {:array, type_schema(type, Keyword.get(constraints, :items, []))}
  end

  defp type_schema(type, constraints) when is_atom(type) do
    if ash_resource?(type),
      do: {:resource, type},
      else: normalized_type_schema(type, constraints)
  end

  defp normalized_type_schema(type, constraints) do
    type = Ash.Type.get_type(type)

    if Ash.Type.NewType.new_type?(type) do
      normalized_type_schema(
        type.subtype_of(),
        Keyword.merge(type.subtype_constraints(), constraints)
      )
    else
      {:type, type, constraints}
    end
  end

  defp parser_dynamic_type?(type, constraints) do
    case normalized_type_schema(type, constraints) do
      {:type, Ash.Type.Term, _constraints} ->
        true

      {:type, Ash.Type.Struct, constraints} ->
        Keyword.get(constraints, :instance_of) in [nil, AshUi.SafeHTML]

      _scalar_or_container ->
        false
    end
  end

  defp ash_resource?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and Ash.Resource.Info.resource?(module)
  rescue
    _error in [ArgumentError, UndefinedFunctionError] -> false
  end

  # ── transform: sentinel substitution, refs keyed by sentinel ──────────────

  defp transform(nodes, addr, refs, resource, target) when is_list(nodes) do
    {nodes, refs, _index} =
      Enum.reduce(nodes, {[], refs, 0}, fn node, {acc, refs, index} ->
        {node, refs} =
          transform(node, addr <> "/" <> Integer.to_string(index), refs, resource, target)

        {[node | acc], refs, index + 1}
      end)

    {Enum.reverse(nodes), refs}
  end

  defp transform(%{kind: :text, content: %CompiledExpr{} = expr}, addr, refs, resource, _target) do
    sentinel = sentinel()
    {text_node(sentinel), Map.put(refs, sentinel, {:text, addr, evaluator(expr, resource)})}
  end

  defp transform(%{kind: :text} = node, _addr, refs, _resource, _target), do: {node, refs}

  # An element with any dynamic attr surface (expr attrs, states, dynamic
  # part, event bindings — see Compiler.element_attr_deps/1) gets its WHOLE
  # attribute region as one dynamic: strip every dynamic input and plant a
  # marker attr; the split expands to the full `<tag ... >` open-tag interior.
  defp transform(%{kind: :element} = node, addr, refs, resource, target) do
    {children, refs} =
      transform_children(Map.get(node, :children, []), addr, refs, resource, target)

    case {AshUi.Patch.Compiler.element_attr_deps(node),
          Map.get(node, :__bp_runtime_attrs__)} do
      {:static, nil} ->
        {Map.put(node, :children, children), refs}

      {_deps, _runtime_attrs} ->
        sentinel = sentinel()

        stripped =
          node
          |> Map.put(:children, children)
          |> Map.put(:attrs, sentinel_attrs(node, sentinel, target))
          |> Map.put(:events, [])
          |> Map.put(:states, [])
          |> strip_dynamic_part()

        ref = {:attrs_chunk, addr, node}

        {stripped, Map.put(refs, sentinel, ref)}
    end
  end

  defp transform(%{kind: :if} = node, addr, refs, resource, _target) do
    sentinel = sentinel()

    ref =
      {:branch_source, addr, evaluator(node.condition, resource),
       %{true: node[:then], false: node[:else]}}

    {text_node(sentinel), Map.put(refs, sentinel, ref)}
  end

  defp transform(%{kind: :when} = node, addr, refs, resource, target) do
    transform(
      %{kind: :if, condition: node.condition, then: node.child, else: nil},
      addr,
      refs,
      resource,
      target
    )
  end

  defp transform(%{kind: :each} = node, addr, refs, resource, _target) do
    sentinel = sentinel()

    ref =
      {:keyed_source, addr, evaluator(node.items, resource),
       %{
         template: node.child,
         as: node.as,
         index: node.index,
         key: node[:key],
         source: node.items,
         parent_deps: AshUi.Patch.Compiler.subtree_state_deps(node.child)
       }}

    {text_node(sentinel), Map.put(refs, sentinel, ref)}
  end

  defp transform(%{kind: :resource_component, resource: child}, addr, refs, _resource, _target)
       when is_atom(child) do
    sentinel = sentinel()
    {text_node(sentinel), Map.put(refs, sentinel, {:child, addr, child})}
  end

  defp transform(
         %{kind: :computed, expr: %CompiledExpr{} = expr},
         addr,
         refs,
         resource,
         _target
       ) do
    sentinel = sentinel()
    {text_node(sentinel), Map.put(refs, sentinel, {:computed, addr, evaluator(expr, resource)})}
  end

  defp transform(%{kind: :computed, expr: nil}, _addr, refs, _resource, _target) do
    {text_node(""), refs}
  end

  defp transform(%{kind: :fragment} = node, addr, refs, resource, target) do
    {children, refs} =
      transform_children(Map.get(node, :children, []), addr, refs, resource, target)

    {Map.put(node, :children, children), refs}
  end

  defp transform(%{kind: kind} = node, _addr, _refs, _resource, _target) do
    raise ArgumentError,
          "AshUi.Patch.Skeleton cannot compile view node kind #{inspect(kind)}: " <>
            inspect(node, limit: 5)
  end

  defp transform(other, _addr, refs, _resource, _target), do: {other, refs}

  defp transform_children(children, addr, refs, resource, target) when is_list(children) do
    transform(children, addr, refs, resource, target)
  end

  defp transform_children(child, addr, refs, resource, target),
    do: transform([child], addr, refs, resource, target)

  defp text_node(content), do: %{kind: :text, content: content}

  # Keep only the presence markers the target finalizer uses to decide
  # whether this element needs a generated DOM id. The complete attribute
  # region is still replaced by one dynamic chunk, but the sentinel oracle
  # can now run the target's ordinary finalize_tree pass over the real tree
  # shape and give that chunk the exact same id as a static render.
  defp sentinel_attrs(node, sentinel, target) do
    attrs = Map.get(node, :attrs, %{})

    finalized_attrs =
      if Code.ensure_loaded?(target) and function_exported?(target, :finalize_skeleton_attrs, 1) do
        target.finalize_skeleton_attrs(attrs)
      else
        %{}
      end

    Map.put(finalized_attrs, "data-bps", sentinel)
  end

  # ── sentinel render: the ordinary full pipeline is the statics oracle ─────

  defp sentinel_html(resource, transformed, target, static_chain, base) do
    compiled = AshUi.Runtime.ResourceInfo.compiled_resource(resource)

    view =
      case transformed do
        nodes when is_list(nodes) -> %{kind: :fragment, children: nodes, __bp_addr__: base}
        node -> node
      end

    tree =
      case AshUi.Runtime.Rendering.render_tree(
             %{compiled | view: view},
             struct(resource),
             %{},
             target: target,
             __bp_chain__: static_chain
           ) do
        {:ok, tree} ->
          tree

        {:error, error} ->
          raise ArgumentError,
                "failed to compile the #{inspect(target)} skeleton for " <>
                  "#{inspect(resource)} at #{inspect(base)}: #{Exception.message(error)}"
      end

    {:safe, iodata} = AshUi.RenderTarget.Html.render_static(tree, target: target)
    IO.iodata_to_binary(iodata)
  end

  # ── split: cut statics at sentinel match regions in document order ────────

  defp split(
         html,
         refs,
         resource,
         target,
         static_chain,
         dynamic_chain?,
         parser_dynamic_text?
       ) do
    matches =
      refs
      |> Enum.map(fn {sentinel, ref} ->
        case :binary.match(html, sentinel) do
          {start, length} ->
            region(html, ref, sentinel, start, length, resource, target)

          :nomatch ->
            # A dynamic that never renders would silently freeze — refuse.
            raise ArgumentError,
                  "dynamic position #{inspect(ref)} did not appear in the rendered skeleton"
        end
      end)
      |> Enum.sort_by(fn {start, _length, _dyn} -> start end)

    {statics, dynamics, cursor} =
      Enum.reduce(matches, {[], [], 0}, fn {start, length, dyn}, {statics, dynamics, cursor} ->
        {[binary_part(html, cursor, start - cursor) | statics],
         [resolve(dyn, resource, target, static_chain, dynamic_chain?) | dynamics],
         start + length}
      end)

    statics = Enum.reverse([binary_part(html, cursor, byte_size(html) - cursor) | statics])
    dynamics = Enum.reverse(dynamics)

    %__MODULE__{
      statics: statics,
      dynamics: dynamics,
      root?: single_rooted?(statics) and not parser_dynamic_text?,
      fingerprint: fingerprint(statics, dynamics)
    }
  end

  # The live host's diff engine does not check fingerprint collisions —
  # 128 bits over statics AND the dynamic shape, like its own engine.
  defp fingerprint(statics, dynamics) do
    shape = Enum.map(dynamics, fn dyn -> {elem(dyn, 0), elem(dyn, 1)} end)
    <<fingerprint::128>> = :erlang.md5(:erlang.term_to_binary({statics, shape}))
    fingerprint
  end

  # root? only when the skeleton is exactly one top-level element with no
  # depth-0 content — fragments and multi-root views must NOT claim root,
  # or the client's root-skip DOM optimization patches the wrong siblings.
  # A structural dynamic boundary is harmless inside an element or its opening
  # tag, but at depth zero it may expand to another root. Represent it as
  # ordinary non-whitespace text so the scanner conservatively rejects it.
  defp single_rooted?(statics) do
    html = Enum.join(statics, " data-ash-ui-dynamic")
    scan_roots(html, 0, 0, false)
  end

  defp scan_roots(<<>>, 0, roots, _in_tag), do: roots == 1
  defp scan_roots(<<>>, _depth, _roots, _in_tag), do: false

  defp scan_roots(<<"</", rest::binary>>, depth, roots, _in_tag) do
    rest = skip_tag(rest)
    scan_roots(rest, max(depth - 1, 0), roots, false)
  end

  defp scan_roots(<<"<", rest::binary>>, depth, roots, _in_tag) do
    {self_closing?, void?, rest} = read_open_tag(rest)

    cond do
      self_closing? or void? ->
        roots = if depth == 0, do: roots + 1, else: roots
        scan_roots(rest, depth, roots, false)

      depth == 0 ->
        scan_roots(rest, 1, roots + 1, false)

      true ->
        scan_roots(rest, depth + 1, roots, false)
    end
  end

  defp scan_roots(<<char::utf8, rest::binary>>, depth, roots, in_tag) do
    if depth == 0 and not whitespace?(char) do
      false
    else
      scan_roots(rest, depth, roots, in_tag)
    end
  end

  @void_tags ~w(area base br col embed hr img input link meta param source track wbr)

  defp read_open_tag(binary) do
    [tag_name | _] = binary |> String.split(~r/[\s>\/]/, parts: 2)
    {inside, rest} = split_tag(binary, "")
    {String.ends_with?(inside, "/"), String.downcase(tag_name) in @void_tags, rest}
  end

  defp split_tag(<<">", rest::binary>>, acc), do: {acc, rest}
  defp split_tag(<<char::utf8, rest::binary>>, acc), do: split_tag(rest, acc <> <<char::utf8>>)
  defp split_tag(<<>>, acc), do: {acc, ""}

  defp skip_tag(binary) do
    case :binary.match(binary, ">") do
      {pos, 1} -> binary_part(binary, pos + 1, byte_size(binary) - pos - 1)
      :nomatch -> ""
    end
  end

  defp whitespace?(char), do: char in [?\s, ?\n, ?\t, ?\r]

  # Attr sentinels: when the rendered region is exactly ` name="SENT"` the
  # whole pair is dynamic (conditional presence); when merged content
  # surrounds the sentinel (theme classes joined into the value) only the
  # value segment is dynamic.
  defp region(html, {:attrs_chunk, addr, node}, _sentinel, start, _length, resource, target) do
    open = scan_back_to_tag_open(html, start)
    close = scan_forward_to_tag_close(html, start)
    node = put_finalized_id(node, html, open, close)
    eval = AshUi.Patch.Compiler.element_attrs_evaluator(node, resource, addr, target)
    {open, close - open, {:attrs, addr, eval}}
  end

  defp region(_html, dyn, _sentinel, start, length, _resource, _target),
    do: {start, length, dyn}

  defp put_finalized_id(node, html, open, close) do
    attrs = Map.get(node, :attrs, %{})

    if authored_id?(attrs) or Map.get(node, :__bp_runtime_attrs__) do
      node
    else
      region = binary_part(html, open, close - open)

      case attr_value(region, "id") do
        nil -> node
        id -> Map.put(node, :attrs, Map.put(attrs, "id", id))
      end
    end
  end

  defp authored_id?(attrs),
    do: Map.has_key?(attrs, "id") or Map.has_key?(attrs, :id)

  defp strip_dynamic_part(%{part: %CompiledExpr{}} = node), do: Map.delete(node, :part)
  defp strip_dynamic_part(node), do: node

  defp attr_value(region, name) do
    prefix = " " <> name <> "=\""

    case :binary.match(region, prefix) do
      {start, prefix_length} ->
        value_start = start + prefix_length
        rest = binary_part(region, value_start, byte_size(region) - value_start)

        case :binary.match(rest, "\"") do
          {length, 1} -> binary_part(rest, 0, length)
          :nomatch -> nil
        end

      :nomatch ->
        nil
    end
  end

  # From the sentinel position back to the end of the tag NAME (the space
  # before the first attribute) — the static keeps `<tag`.
  defp scan_back_to_tag_open(html, position) do
    lt = scan_back_to(html, position, ?<)
    scan_forward_to_space(html, lt)
  end

  defp scan_back_to(html, position, byte) do
    case binary_part(html, position, 1) do
      <<^byte>> -> position
      _other -> scan_back_to(html, position - 1, byte)
    end
  end

  defp scan_forward_to_space(html, position) do
    case binary_part(html, position, 1) do
      " " -> position
      _other -> scan_forward_to_space(html, position + 1)
    end
  end

  defp scan_forward_to_tag_close(html, position) do
    case binary_part(html, position, 1) do
      ">" -> position
      _other -> scan_forward_to_tag_close(html, position + 1)
    end
  end

  # ── late resolution: arms/items compile recursively as skeletons ──────────

  defp resolve(
         {:branch_source, addr, cond_eval, arms},
         resource,
         target,
         static_chain,
         dynamic_chain?
       ) do
    {:branch, addr, cond_eval,
     %{
       true:
         arms
         |> Map.get(true)
         |> compile_subtree(resource, addr <> "/t", target, static_chain, dynamic_chain?),
       false:
         arms
         |> Map.get(false)
         |> compile_subtree(resource, addr <> "/f", target, static_chain, dynamic_chain?)
     }}
  end

  defp resolve(
         {:keyed_source, addr, items_eval, meta},
         resource,
         target,
         static_chain,
         _dynamic_chain?
       ) do
    {:keyed, addr, items_eval,
     %{
       skeleton:
         compile_subtree(meta.template, resource, addr <> "/*", target, static_chain, true),
       as: meta.as,
       index: meta.index,
       source: meta.source,
       key_eval: key_evaluator(meta.key, resource),
       parent_deps: meta.parent_deps,
       item_deps:
         AshUi.Patch.Compiler.keyed_item_deps(%{as: meta.as, child: meta.template})
     }}
  end

  defp resolve({:computed, addr, eval}, _resource, _target, _static_chain, _dynamic_chain?),
    do: {:computed, addr, eval}

  defp resolve(dyn, _resource, _target, _static_chain, _dynamic_chain?), do: dyn

  defp key_evaluator(%CompiledExpr{} = expr, resource), do: evaluator(expr, resource)
  defp key_evaluator(_other, _resource), do: nil

  defp compile_subtree(nil, _resource, _base, _target, _static_chain, _dynamic_chain?), do: nil
  defp compile_subtree([], _resource, _base, _target, _static_chain, _dynamic_chain?), do: nil

  defp compile_subtree(node, resource, base, target, static_chain, dynamic_chain?),
    do:
      compile(resource, List.wrap(node),
        base: base,
        target: target,
        static_chain: static_chain,
        dynamic_chain?: dynamic_chain?
      )

  # ── helpers ────────────────────────────────────────────────────────────────

  defp evaluator(value, resource), do: Evaluator.compile(value, resource)

  defp sentinel do
    "bps" <> (:erlang.unique_integer([:positive, :monotonic]) |> Integer.to_string(36)) <> "e"
  end
end
