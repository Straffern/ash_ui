defmodule AshUi.Verifiers.VerifyExpressions do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Ash.Query.{Call, Ref}
  alias AshUi.EventBinding
  alias AshUi.Verifiers.Helpers

  @impl true
  def verify(dsl_state) do
    resource = Helpers.compiled_resource!(dsl_state)

    case emit_or_return(dsl_state, :strict, theming_contract_diagnostics(resource)) do
      {:error, error} ->
        raise error

      :ok ->
        case Map.get(resource, :strict_expressions?, :strict) do
          :off ->
            :ok

          mode ->
            diagnostics =
              resource
              |> collect_expression_terms()
              |> Enum.flat_map(fn {term, path} ->
                verify_expression_term(resource, term, path)
              end)
              |> Kernel.++(typed_item_field_diagnostics(resource))

            case emit_or_return(dsl_state, mode, diagnostics) do
              {:error, error} -> raise error
              other -> other
            end
        end
    end
  end

  defp collect_expression_terms(resource) do
    []
    |> collect_from(resource.view, [:view])
    |> collect_each(resource.actions, [:actions], fn action, path, acc ->
      collect_from(acc, action, path ++ [Map.get(action, :name)])
    end)
  end

  defp collect_each(acc, values, base_path, fun) when is_list(values) do
    Enum.reduce(values, acc, fn value, next_acc ->
      fun.(value, base_path, next_acc)
    end)
  end

  defp collect_from(acc, nil, _path), do: acc

  defp collect_from(acc, %Call{} = call, path) do
    acc
    |> maybe_collect_expression(call, path)
    |> collect_from(call.args, path ++ [:args])
  end

  defp collect_from(acc, %EventBinding{} = binding, path) do
    acc
    |> collect_from(binding.args_exprs, path ++ [:args])
    |> collect_from(Map.get(binding.meta || %{}, :key_filter), path ++ [:when])
  end

  defp collect_from(acc, tuple, path) when is_tuple(tuple) do
    acc = maybe_collect_expression(acc, tuple, path)

    tuple
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {value, index}, next_acc ->
      collect_from(next_acc, value, path ++ [index])
    end)
  end

  defp collect_from(acc, values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {value, index}, next_acc ->
      collect_from(next_acc, value, path ++ [index])
    end)
  end

  defp collect_from(acc, %_struct{} = struct, path) do
    collect_from(acc, Map.from_struct(struct), path)
  end

  defp collect_from(acc, %{} = map, path) do
    Enum.reduce(map, acc, fn {key, value}, next_acc ->
      collect_from(next_acc, value, path ++ [key])
    end)
  end

  defp collect_from(acc, _value, _path), do: acc

  defp maybe_collect_expression(acc, %Call{} = call, path)
       when call.name in [
              :item,
              :index,
              :event,
              :part_id,
              :child,
              :result,
              :errors,
              :path_for,
              :path,
              :get_path
            ],
       do: [{call, path} | acc]

  defp maybe_collect_expression(acc, tuple, path) when is_tuple(tuple) do
    if tuple_marker?(tuple), do: [{tuple, path} | acc], else: acc
  end

  defp maybe_collect_expression(acc, _term, _path), do: acc

  defp tuple_marker?(tuple) when tuple_size(tuple) > 0 do
    marker =
      tuple
      |> elem(0)

    marker in [:_item, :_index, :_event, :_part_id, :_child, :_result, :_errors, :_path_for]
  end

  defp tuple_marker?(_other), do: false

  defp verify_expression_term(resource, %Call{name: name, args: args}, path) do
    verify_accessor(resource, name, args, path)
  end

  defp verify_expression_term(resource, tuple, path) when is_tuple(tuple) do
    marker =
      tuple
      |> elem(0)

    args = tuple |> Tuple.to_list() |> tl()
    name = accessor_name(marker, length(args)) || marker

    verify_accessor(resource, name, args, path)
  end

  defp verify_accessor(_resource, :path_for, _args, path) do
    [
      {:error, path,
       "path_for is not supported. " <>
         "Declare routes on resources and navigate with link(to: path) or a route location expression. " <>
         "See the ash_ui DESIGN.md §8."}
    ]
  end

  defp verify_accessor(resource, name, [value, segments], path)
       when name in [:path, :get_path] and is_list(segments) do
    verify_static_path(resource, value, segments, path)
  end

  defp verify_accessor(_resource, _name, _args, _path), do: []

  defp verify_static_path(_resource, _value, [], _path), do: []

  defp verify_static_path(resource, value, [field | _rest] = segments, path)
       when is_atom(field) or is_binary(field) do
    case typed_path_base(resource, value) do
      {:typed, name, type} ->
        [
          {:error, path,
           "path(#{inspect(name)}, ...) digs a TYPED value (#{inspect(type)}) — " <>
             "reference the field directly (bare ref); path() is only for " <>
             "declared-opaque maps ([opaque] description)"}
        ]

      :opaque_or_unknown ->
        case static_shape(resource, value) do
          {:ok, subject, fields} ->
            verify_field(subject, fields, field, value, segments, path)

          :unknown ->
            []
        end
    end
  end

  defp verify_static_path(_resource, _value, _segments, _path), do: []

  # F3: path() over a value whose declared type is NOT an opaque map is
  # a compile error — typed data uses bare refs.
  defp typed_path_base(resource, {:_ref, [], name}) when is_atom(name) do
    field =
      Enum.find(
        resource.attributes ++ resource.calculations,
        &(Map.get(&1, :name) == name)
      )

    case field do
      nil ->
        :opaque_or_unknown

      field ->
        type = Map.get(field, :type)

        cond do
          untyped_map_type?(type) and not opaque_description?(Map.get(field, :description)) ->
            # untyped without [opaque] is already a TypedInputs error for
            # public fields; private untyped maps may still be path()ed
            :opaque_or_unknown

          untyped_map_type?(type) ->
            :opaque_or_unknown

          true ->
            {:typed, name, type}
        end
    end
  end

  defp typed_path_base(_resource, _value), do: :opaque_or_unknown

  defp untyped_map_type?({:array, inner}), do: untyped_map_type?(inner)
  defp untyped_map_type?(type), do: type in [:map, :term, Ash.Type.Map, Ash.Type.Term]

  defp opaque_description?(description) when is_binary(description),
    do: description =~ "[opaque]"

  defp opaque_description?(_description), do: false

  defp typed_item_field_diagnostics(resource) do
    collect_typed_item_fields(resource, resource.view, [:view], %{})
  end

  defp collect_typed_item_fields(_resource, nil, _path, _scope), do: []

  defp collect_typed_item_fields(
         resource,
         %{kind: :each, items: items, as: as, child: child} = node,
         path,
         scope
       ) do
    own_diagnostics =
      node
      |> Map.drop([:child])
      |> collect_typed_item_terms(resource, path, scope)

    child_scope =
      case static_shape(resource, items) do
        {:ok, _subject, _fields} = shape when is_atom(as) -> Map.put(scope, as, shape)
        _other -> scope
      end

    own_diagnostics ++ collect_typed_item_fields(resource, child, path ++ [:child], child_scope)
  end

  defp collect_typed_item_fields(
         resource,
         %{kind: :fragment, children: children} = node,
         path,
         scope
       ) do
    collect_typed_item_terms(Map.drop(node, [:children]), resource, path, scope) ++
      collect_typed_item_children(resource, children, path, scope)
  end

  defp collect_typed_item_fields(resource, %{kind: kind, children: children} = node, path, scope)
       when kind in [:stack, :row, :element, :part] do
    collect_typed_item_terms(Map.drop(node, [:children]), resource, path, scope) ++
      collect_typed_item_children(resource, children, path, scope)
  end

  defp collect_typed_item_fields(resource, %{kind: :when, child: child} = node, path, scope) do
    collect_typed_item_terms(Map.drop(node, [:child]), resource, path, scope) ++
      collect_typed_item_fields(resource, child, path ++ [:child], scope)
  end

  defp collect_typed_item_fields(resource, %{kind: :if, then: then_child} = node, path, scope) do
    collect_typed_item_terms(Map.drop(node, [:then, :else]), resource, path, scope) ++
      collect_typed_item_fields(resource, then_child, path ++ [:then], scope) ++
      collect_typed_item_fields(resource, Map.get(node, :else), path ++ [:else], scope)
  end

  defp collect_typed_item_fields(
         resource,
         %{kind: :attached_view, child: child} = node,
         path,
         scope
       ) do
    collect_typed_item_terms(Map.drop(node, [:child]), resource, path, scope) ++
      collect_typed_item_fields(resource, child, path ++ [:child], scope)
  end

  defp collect_typed_item_fields(
         resource,
         %{kind: :resource_component, fills: fills} = node,
         path,
         scope
       ) do
    collect_typed_item_terms(Map.drop(node, [:fills]), resource, path, scope) ++
      Enum.flat_map(fills || %{}, fn {slot, children} ->
        children
        |> List.wrap()
        |> Enum.with_index()
        |> Enum.flat_map(fn {child, index} ->
          collect_typed_item_fields(resource, child, path ++ [:fills, slot, index], scope)
        end)
      end)
  end

  defp collect_typed_item_fields(resource, %{} = node, path, scope) do
    collect_typed_item_terms(node, resource, path, scope)
  end

  defp collect_typed_item_fields(_resource, _other, _path, _scope), do: []

  defp collect_typed_item_children(resource, children, path, scope) do
    children
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} ->
      collect_typed_item_fields(resource, child, path ++ [index], scope)
    end)
  end

  defp collect_typed_item_terms(term, resource, path, scope) do
    []
    |> collect_from(term, path)
    |> Enum.flat_map(fn {item_term, item_path} ->
      verify_scoped_item_term(resource, scope, item_term, item_path)
    end)
  end

  defp verify_scoped_item_term(_resource, scope, %Call{name: :item, args: [binding, field]}, path) do
    verify_scoped_item_field(scope, binding, field, path)
  end

  defp verify_scoped_item_term(_resource, scope, tuple, path) when is_tuple(tuple) do
    case tuple do
      {:_item, binding, field} -> verify_scoped_item_field(scope, binding, field, path)
      {:item, binding, field} -> verify_scoped_item_field(scope, binding, field, path)
      _other -> []
    end
  end

  defp verify_scoped_item_term(_resource, _scope, _term, _path), do: []

  defp verify_scoped_item_field(scope, binding, field, path) when is_atom(binding) do
    with {:ok, segments} <- item_field_segments(field),
         {:ok, {:ok, subject, fields}} <- Map.fetch(scope, binding) do
      [first | _rest] = segments
      verify_item_field(subject, fields, binding, segments, first, path)
    else
      _other -> []
    end
  end

  defp verify_scoped_item_field(_scope, _binding, _field, _path), do: []

  defp item_field_segments([]), do: :error
  defp item_field_segments(field) when is_atom(field) or is_binary(field), do: {:ok, [field]}

  defp item_field_segments([field | _rest] = fields)
       when is_atom(field) or is_binary(field),
       do: {:ok, fields}

  defp item_field_segments(_field), do: :error

  defp verify_item_field(subject, fields, binding, segments, field, path) do
    normalized = normalize_field_name(field)

    if normalized in Enum.map(fields, &normalize_field_name/1) do
      []
    else
      suggestion = did_you_mean(field, fields)

      [
        {:error, path,
         "#{format_item_expr(binding, segments)} - #{subject} has no field #{inspect(field)}.#{suggestion}"}
      ]
    end
  end

  defp static_shape(resource, %AshUi.Expr.Compiled{ir: ir}) do
    static_shape(resource, ir)
  end

  defp static_shape(resource, {:_ref, [], name}) when is_atom(name) do
    read_shape(resource, name)
  end

  defp static_shape(resource, %Ref{relationship_path: [], attribute: name}) when is_atom(name) do
    read_shape(resource, name)
  end

  defp static_shape(_resource, _value), do: :unknown

  defp read_shape(resource, read_name) do
    resource.relationships
    |> List.wrap()
    |> Enum.find(&(Map.get(&1, :name) == read_name))
    |> case do
      %{destination_resource: %AshUi.ResourceBlueprint{} = destination} ->
        {:ok, inspect(destination.module || destination.name), blueprint_field_names(destination)}

      %{destination: module} when is_atom(module) ->
        case ash_field_names(module) do
          {:ok, fields} -> {:ok, inspect(module), fields}
          :unknown -> :unknown
        end

      _other ->
        :unknown
    end
  end

  defp blueprint_field_names(resource) do
    []
    |> Kernel.++(Enum.map(resource.attributes || [], & &1.name))
    |> Kernel.++(Enum.map(resource.relationships || [], & &1.name))
    |> Kernel.++(Enum.map(resource.calculations || [], & &1.name))
    |> Kernel.++(Enum.map(Map.get(resource, :aggregates) || [], & &1.name))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp ash_field_names(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      fields =
        []
        |> Kernel.++(Enum.map(Ash.Resource.Info.attributes(module), & &1.name))
        |> Kernel.++(Enum.map(Ash.Resource.Info.relationships(module), & &1.name))
        |> Kernel.++(Enum.map(Ash.Resource.Info.calculations(module), & &1.name))
        |> maybe_add_ash_aggregates(module)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, fields}
    else
      :unknown
    end
  rescue
    error in [ArgumentError, UndefinedFunctionError] ->
      _ = error
      :unknown
  end

  defp maybe_add_ash_aggregates(fields, module) do
    if function_exported?(Ash.Resource.Info, :aggregates, 1) do
      fields ++ Enum.map(Ash.Resource.Info.aggregates(module), & &1.name)
    else
      fields
    end
  rescue
    error in [ArgumentError, UndefinedFunctionError] ->
      _ = error
      fields
  end

  defp verify_field(subject, fields, field, value, segments, path) do
    normalized = normalize_field_name(field)

    if normalized in Enum.map(fields, &normalize_field_name/1) do
      []
    else
      suggestion = did_you_mean(field, fields)

      [
        {:error, path,
         "#{format_path_expr(value, segments)} - #{subject} has no field #{inspect(field)}.#{suggestion}"}
      ]
    end
  end

  defp normalize_field_name(field) when is_atom(field), do: Atom.to_string(field)
  defp normalize_field_name(field) when is_binary(field), do: field
  defp normalize_field_name(field), do: inspect(field)

  defp did_you_mean(field, fields) do
    field_name = normalize_field_name(field)

    fields
    |> Enum.map(fn candidate ->
      {candidate, String.jaro_distance(field_name, normalize_field_name(candidate))}
    end)
    |> Enum.filter(fn {_candidate, score} -> score >= 0.75 end)
    |> Enum.sort_by(fn {_candidate, score} -> score end, :desc)
    |> case do
      [{candidate, _score} | _rest] -> " Did you mean #{inspect(candidate)}?"
      [] -> ""
    end
  end

  defp format_path_expr({:_ref, [], name}, segments) do
    "path(#{name}, #{inspect(segments)})"
  end

  defp format_path_expr(%Ref{relationship_path: [], attribute: name}, segments) do
    "path(#{name}, #{inspect(segments)})"
  end

  defp format_path_expr(_value, segments), do: "path(..., #{inspect(segments)})"

  defp format_item_expr(binding, [field]), do: "item(#{inspect(binding)}, #{inspect(field)})"
  defp format_item_expr(binding, segments), do: "item(#{inspect(binding)}, #{inspect(segments)})"

  defp accessor_name(:_item, 2), do: :item
  defp accessor_name(:_index, 1), do: :index
  defp accessor_name(:_event, 1), do: :event
  defp accessor_name(:_part_id, 1), do: :part_id
  defp accessor_name(:_child, 2), do: :child
  defp accessor_name(:_result, arity) when arity in [0, 1], do: :result
  defp accessor_name(:_errors, 0), do: :errors
  defp accessor_name(:_path_for, 3), do: :path_for
  defp accessor_name(_marker, _arity), do: nil

  # DESIGN.md §9: structure and paint are strictly split. A view emits only a
  # bare `part` attribute and ARIA-first state attributes; presentation binds
  # to `[part=...]` in stylesheets. A `class`/`style` authored on a view node
  # is a second, unverifiable paint channel, so it is banned unconditionally
  # (there is no opt-out).
  defp theming_contract_diagnostics(resource) do
    collect_theming_contract_diagnostics(resource.view, [:view])
  end

  defp presentation_attr_message(attr) do
    """
    This AshUi view node authors a raw `#{attr}` attribute.

    Structure and paint are strictly split: a view emits only a bare `part`
    attribute plus ARIA-first state attributes, and all presentation binds to
    `[part=...]` selectors in the resource's effective stylesheets. An authored
    class/style is a second paint channel the coverage verifier cannot see.

    Remove the class/style and give the node a semantic part, then style it in a
    declared stylesheet:

        # view
        item(:card, [part: :artist_card, state: [selected: selected?]], [...])

        /* assets/css/app.css */
        [part="artist_card"] { /* paint here */ }
        [part="artist_card"][aria-selected="true"] { /* selected paint */ }

    The sole exemption is framework-generated icon classes
    (`generated_class: :typed_icon_name`). See the ash_ui DESIGN.md §9.\
    """
  end

  defp dynamic_part_message(part) do
    """
    This AshUi view node authors a dynamic `part`: #{inspect(part, limit: 5)}.

    Part names are compile-time styling contracts. Every part emitted by a
    routed document and its render() closure must match a literal `[part=...]`
    selector in the effective stylesheets, so a runtime-computed part cannot be
    coverage-verified.

    Replace the expression with a literal atom or string and express changing
    state through `state:` (`aria-*` for standard state, `data-*` for custom
    state). See the ash_ui DESIGN.md §9.\
    """
  end

  defp collect_theming_contract_diagnostics(nil, _path), do: []

  defp collect_theming_contract_diagnostics(%{kind: :element} = node, path) do
    attrs = Map.get(node, :attrs) || %{}

    presentation_diagnostics =
      ["class", "style"]
      |> Enum.filter(fn attr ->
        authored_attr?(node, attrs, attr) and
          not (attr == "class" and generated_class_node?(node))
      end)
      |> Enum.map(&{:error, path, presentation_attr_message(&1)})

    part_diagnostics =
      case Map.get(node, :part) do
        part when is_nil(part) or is_atom(part) or is_binary(part) ->
          []

        part ->
          [{:error, path ++ [:part], dynamic_part_message(part)}]
      end

    presentation_diagnostics ++
      part_diagnostics ++ collect_children_diagnostics(Map.get(node, :children), path)
  end

  defp collect_theming_contract_diagnostics(%{kind: :resource_component} = node, path) do
    node
    |> Map.get(:assigns, %{})
    |> Map.values()
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      collect_theming_contract_diagnostics(value, path ++ [:assigns, index])
    end)
  end

  defp collect_theming_contract_diagnostics(%{kind: :if} = node, path) do
    collect_theming_contract_diagnostics(Map.get(node, :then), path ++ [:then]) ++
      collect_theming_contract_diagnostics(Map.get(node, :else), path ++ [:else])
  end

  defp collect_theming_contract_diagnostics(%{child: child}, path),
    do: collect_theming_contract_diagnostics(child, path ++ [:child])

  defp collect_theming_contract_diagnostics(%{children: children}, path),
    do: collect_children_diagnostics(children, path)

  defp collect_theming_contract_diagnostics(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      collect_theming_contract_diagnostics(value, path ++ [index])
    end)
  end

  defp collect_theming_contract_diagnostics(_other, _path), do: []

  defp collect_children_diagnostics(children, path) do
    children
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} ->
      collect_theming_contract_diagnostics(child, path ++ [index])
    end)
  end

  defp authored_attr?(node, attrs, attr) do
    Map.has_key?(attrs, attr) or
      Map.has_key?(attrs, String.to_atom(attr)) or
      not is_nil(Map.get(node, String.to_atom(attr)))
  end

  defp generated_class_node?(%{meta: %{generated_class: :typed_icon_name}}), do: true
  defp generated_class_node?(_node), do: false

  defp emit_or_return(_dsl_state, _mode, []), do: :ok

  defp emit_or_return(dsl_state, :warn, diagnostics) do
    module = Helpers.module!(dsl_state)

    Enum.each(diagnostics, fn {_level, path, message} ->
      IO.warn("#{inspect(module)} #{inspect(path)}: #{message}", [])
    end)

    :ok
  end

  defp emit_or_return(dsl_state, :strict, diagnostics) do
    case Enum.find(diagnostics, &match?({:error, _path, _message}, &1)) do
      nil ->
        emit_or_return(dsl_state, :warn, diagnostics)

      {:error, path, message} ->
        {:error, Helpers.dsl_error(dsl_state, path, message)}
    end
  end
end
