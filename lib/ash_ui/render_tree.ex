defmodule AshUi.RenderTree do
  @moduledoc """
  Adapter-neutral rendered output produced from a semantic view tree.

  Structure and paint are strictly split (DESIGN.md §9): this lowering emits only
  bare `part` attributes and ARIA-first state attributes. It applies no theme —
  there are no part→class rules, no theme assets, no `is-<state>` classes.
  Served DOM carries no class attributes.
  """

  alias AshUi.{AttrMerge, EventBinding}
  alias AshUi.RenderTree.{Element, Fragment, Portal, Text}

  defmodule Element do
    defstruct [:key, :tag, attrs: %{}, children: [], event_bindings: [], meta: %{}]

    @opaque t :: %__MODULE__{
              key: term(),
              tag: atom() | nil,
              attrs: map(),
              children: list(),
              event_bindings: [EventBinding.t()],
              meta: map()
            }
  end

  defmodule Text do
    defstruct [:key, :content]

    @opaque t :: %__MODULE__{key: term(), content: term()}
  end

  defmodule Fragment do
    defstruct [:key, children: []]

    @opaque t :: %__MODULE__{key: term(), children: list()}
  end

  defmodule Portal do
    defstruct [:key, :target, children: []]

    @opaque t :: %__MODULE__{key: term(), target: term(), children: list()}
  end

  @type t :: Element.t() | Text.t() | Fragment.t() | Portal.t()

  @spec element(atom() | nil, map(), [t()], keyword()) :: Element.t()
  def element(tag, attrs \\ %{}, children \\ [], opts \\ [])
      when (is_atom(tag) or is_nil(tag)) and is_map(attrs) and is_list(children) and
             is_list(opts) do
    %Element{
      key: Keyword.get(opts, :key),
      tag: tag,
      attrs: attrs,
      children: children,
      event_bindings: Keyword.get(opts, :event_bindings, []),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @spec text(term(), keyword()) :: Text.t()
  def text(content, opts \\ []) when is_list(opts) do
    %Text{key: Keyword.get(opts, :key), content: content}
  end

  @spec fragment([t()], keyword()) :: Fragment.t()
  def fragment(children \\ [], opts \\ []) when is_list(children) and is_list(opts) do
    %Fragment{key: Keyword.get(opts, :key), children: children}
  end

  @spec portal(term(), [t()], keyword()) :: Portal.t()
  def portal(target, children \\ [], opts \\ []) when is_list(children) and is_list(opts) do
    %Portal{key: Keyword.get(opts, :key), target: target, children: children}
  end

  @spec render(map() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def render(tree, opts \\ []) when is_list(opts) do
    target = Keyword.get(opts, :target, AshUi.RenderTarget.Static)

    with {:ok, rendered_tree} <- do_render(tree, nil) do
      {:ok, target.finalize_tree(rendered_tree)}
    end
  end

  defp do_render(nil, _template_name), do: {:ok, nil}

  defp do_render(%Element{children: children} = element, template_name) do
    with {:ok, rendered_children} <- render_children(children, template_name) do
      rendered_element =
        element
        |> Map.put(:children, rendered_children)
        |> maybe_apply_node_states()

      {:ok, rendered_element}
    end
  end

  defp do_render(%Text{} = text, _template_name), do: {:ok, text}

  defp do_render(%Fragment{children: children} = fragment, template_name) do
    with {:ok, rendered_children} <- render_children(children, template_name) do
      {:ok, %{fragment | children: rendered_children}}
    end
  end

  defp do_render(%Portal{children: children} = portal, template_name) do
    with {:ok, rendered_children} <- render_children(children, template_name) do
      {:ok, %{portal | children: rendered_children}}
    end
  end

  defp do_render(%{kind: :fragment, children: children} = node, template_name) do
    with {:ok, rendered_children} <- render_children(children, template_name) do
      {:ok, %Fragment{key: Map.get(node, :key), children: rendered_children}}
    end
  end

  defp do_render(%{kind: kind, children: children} = node, template_name)
       when kind in [:stack, :row] do
    node_options = Map.get(node, :options, %{})

    with {:ok, rendered_children} <- render_children(children, template_name) do
      {:ok,
       %Element{
         key: Map.get(node, :key),
         tag: :div,
         attrs: %{},
         children: rendered_children,
         meta: part_meta(kind, node_options) |> maybe_put_part_contract(kind)
       }}
    end
  end

  defp do_render(%{kind: :text, content: content} = node, _template_name) do
    {:ok, %Text{key: Map.get(node, :key), content: content}}
  end

  defp do_render(
         %{kind: :component, component: component_name, view: view} = node,
         _current_template
       ) do
    with {:ok, rendered_tree} <- do_render(view, component_name) do
      case rendered_tree do
        %Fragment{} = fragment ->
          {:ok, %Fragment{fragment | key: Map.get(node, :key, fragment.key)}}

        nil ->
          {:ok, nil}

        rendered_tree ->
          {:ok, put_render_key(rendered_tree, Map.get(node, :key))}
      end
    end
  end

  defp do_render(
         %{
           kind: :element,
           tag: tag,
           attrs: attrs,
           events: events,
           children: children,
           meta: meta
         } = node,
         template_name
       ) do
    with {:ok, rendered_children} <- render_children(children, template_name) do
      component_part = Map.get(node, :part) || Map.get(meta, :component_part)
      data_part = component_part || inferred_part(tag, meta)

      active_states =
        node
        |> Map.get(:states, [])
        |> Enum.filter(&part_state_active?/1)
        |> Enum.map(& &1.name)
        |> Enum.uniq()

      meta =
        meta
        |> Map.new()
        |> maybe_put_component_part(component_part)
        |> maybe_put_component_part_states(active_states)
        |> maybe_put_part_contract(data_part)

      rendered_element =
        %Element{
          key: Map.get(node, :key, Map.get(meta, :key)),
          tag: tag,
          attrs: attrs,
          event_bindings: events,
          children: rendered_children,
          meta: meta
        }
        |> maybe_apply_node_states()

      {:ok, rendered_element}
    end
  end

  defp do_render(%{kind: :when, visible?: false}, _template_name),
    do: {:ok, nil}

  defp do_render(%{kind: :when, visible?: true, child: child} = node, template_name) do
    with {:ok, rendered_child} <- do_render(child, template_name) do
      {:ok, put_render_key(rendered_child, Map.get(node, :key))}
    end
  end

  defp do_render(other, _template_name) do
    {:error, {:unsupported_render_tree_node, other}}
  end

  defp render_children(children, template_name) do
    Enum.reduce_while(children, {:ok, []}, fn child, {:ok, acc} ->
      case do_render(child, template_name) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, rendered_child} -> {:cont, {:ok, [rendered_child | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rendered_children} -> {:ok, Enum.reverse(rendered_children)}
      error -> error
    end
  end

  defp maybe_put_component_part(meta, nil), do: meta

  defp maybe_put_component_part(meta, part_name),
    do: Map.put_new(meta, :component_part, part_name)

  defp maybe_put_component_part_states(meta, []), do: meta

  defp maybe_put_component_part_states(meta, states),
    do: Map.put_new(meta, :component_part_states, states)

  defp maybe_put_part_contract(meta, nil), do: meta
  defp maybe_put_part_contract(meta, part), do: Map.put_new(meta, :part, part)

  defp part_state_active?(%{when: false}), do: false
  defp part_state_active?(_state), do: true

  # Node states lower to ARIA-first attributes only (DESIGN.md §9): served DOM
  # carries NO class attributes. selected/open/disabled → aria-*, custom
  # states → data-*. The HTML target derives the same attrs from meta on the
  # element render path, so the byte oracle holds.
  defp maybe_apply_node_states(%Element{meta: meta} = element) do
    states =
      meta
      |> Map.get(:node_states, [])
      |> List.wrap()

    case states do
      [] ->
        element

      states ->
        state_attrs =
          Enum.reduce(states, %{}, fn state, attrs -> put_state_attr(attrs, state) end)

        %Element{element | attrs: AttrMerge.merge_tree_attrs(element.attrs, state_attrs)}
    end
  end

  defp put_state_attr(attrs, :selected), do: Map.put(attrs, "aria-selected", "true")
  defp put_state_attr(attrs, :open), do: Map.put(attrs, "aria-expanded", "true")
  defp put_state_attr(attrs, :disabled), do: Map.put(attrs, "aria-disabled", "true")

  defp put_state_attr(attrs, state) do
    Map.put(attrs, "data-#{state |> to_string() |> String.replace("_", "-")}", "true")
  end

  defp part_meta(kind, options) when map_size(options) == 0, do: %{node: kind}
  defp part_meta(kind, options), do: %{node: kind, options: options}

  defp inferred_part(_tag, %{part: part}) when is_atom(part) or is_binary(part), do: part

  defp inferred_part(_tag, %{component_part: part}) when is_atom(part) or is_binary(part),
    do: part

  defp inferred_part(_tag, %{node: node}) when is_atom(node) or is_binary(node), do: node

  defp inferred_part(_tag, %{semantic: {_kind, name}})
       when is_atom(name) or is_binary(name),
       do: name

  defp inferred_part(tag, _meta) when is_atom(tag) or is_binary(tag), do: tag
  defp inferred_part(_tag, _meta), do: nil

  defp put_render_key(node, nil), do: node
  defp put_render_key(%Element{} = node, key), do: %{node | key: key}
  defp put_render_key(%Fragment{} = node, key), do: %{node | key: key}
  defp put_render_key(%Text{} = node, key), do: %{node | key: key}
  defp put_render_key(%Portal{} = node, key), do: %{node | key: key}
end
