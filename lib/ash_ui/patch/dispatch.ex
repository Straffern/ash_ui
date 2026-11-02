defmodule AshUi.Patch.Dispatch do
  @moduledoc """
  ONE dispatch semantics, backing-blind (DESIGN.md §5): run the target
  instance's OWN action — arguments, validations, changes, never bypassed
  — and persist through the instance's data layer. The storage seam is the
  only place backing appears:

  - store-backed: `update/4` — an ordinary update on the instance's row.
  - embedded: `embedded_update/5` — the instance's data layer IS the
    parent attribute (Ash's own semantics). The embedded action runs
    against the instance located by primary key inside the parent
    attribute (scalar, or `{:array, Embedded}`; an absent key inserts a
    defaults instance with the action applied), and the result persists as
    exactly ONE parent update — one parent notification.

  Errors surface: an embedded action's validation error returns the same
  `{:error, _}` shape a store-backed action's would.
  """

  @type path_segment :: atom() | {:item, term()}

  @doc """
  THE dispatch entry point — backing-blind. `target` is what
  `AshUi.Patch.Bindings.resolve/3` returns; callers never branch on
  backing:

      run(record, {:root}, action, params, opts)
      run(record, {:row, child_row}, action, params, opts)
      run(record, {:embedded, parent, path}, action, params, opts)

  Returns `{:ok, updated_instance_owner}` — the root record, the child
  row, or the parent — or `{:error, reason}` in one shape for all three.
  """
  @spec run(struct(), tuple(), atom(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def run(record, target, action, params, opts \\ [])

  def run(%resource{} = record, {:root}, action, params, opts),
    do: run_record_action(record, action, action_params(resource, action, params), opts)

  def run(%_{}, {:row, %resource{} = row}, action, params, opts) do
    with {:ok, row} <- ensure_store_row(row, opts) do
      run_record_action(row, action, action_params(resource, action, params), opts)
    end
  end

  def run(%_{}, {:embedded, %_{} = parent, path}, action, params, opts) do
    resource = embedded_resource(parent.__struct__, path)
    params = action_params(resource, action, params)

    case Ash.Resource.Info.action(resource, action) do
      %{type: :update} -> embedded_update(parent, path, action, params, opts)
      %{type: :destroy} -> embedded_destroy(parent, path, action, params, opts)
      %{type: :action} -> run_generic_action(resource, parent, action, params, opts)
      %{type: type} -> {:error, {:unsupported_instance_action, type, action}}
      nil -> {:error, {:unknown_action, resource, action}}
    end
  end

  def run(%_{}, target, _action, _params, _opts), do: {:error, {:unknown_target, target}}

  @doc false
  def target_resource(%resource{}, {:root}), do: resource
  def target_resource(%_{}, {:row, %resource{}}), do: resource

  def target_resource(%_{}, {:embedded, %parent{}, path}),
    do: embedded_resource(parent, path)

  def target_resource(%_{}, _target), do: nil

  @doc false
  # Storage seam, store-backed half: the instance's own action on its row.
  def update(%resource{} = record, action, params, opts \\ []) do
    record
    |> Ash.Changeset.for_update(action, params, changeset_opts(resource, opts))
    |> Ash.update(update_opts(resource, opts))
  end

  defp run_record_action(%resource{} = record, action, params, opts) do
    case Ash.Resource.Info.action(resource, action) do
      %{type: :update} -> update(record, action, params, opts)
      %{type: :destroy} -> destroy(record, action, params, opts)
      %{type: :action} -> run_generic_action(resource, record, action, params, opts)
      %{type: type} -> {:error, {:unsupported_instance_action, type, action}}
      nil -> {:error, {:unknown_action, resource, action}}
    end
  end

  defp destroy(%resource{} = record, action, params, opts) do
    record
    |> Ash.Changeset.for_destroy(action, params, changeset_opts(resource, opts))
    |> Ash.destroy(Keyword.put(update_opts(resource, opts), :return_destroyed?, true))
  end

  defp run_generic_action(resource, owner, action, params, opts) do
    result =
      resource
      |> Ash.ActionInput.for_action(action, params, changeset_opts(resource, opts))
      |> Ash.run_action(update_opts(resource, opts))

    case result do
      :ok -> {:ok, owner}
      {:ok, _result} -> {:ok, owner}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Storage seam, embedded half: run `action` on the instance at `path`
  # ([:folds, {:item, pk}], [:current_fold], nested chains fold) and
  # persist as ONE parent update writing the changed attribute.
  def embedded_update(%parent{} = record, [attr | rest], action, params, opts \\ [])
      when is_atom(attr) do
    with %{type: type} <- attribute!(parent, attr),
         {:ok, new_value} <-
           apply_in(type, Map.get(record, attr), rest, action, params, opts) do
      record
      |> Ash.Changeset.for_update(write_action(parent, opts), %{}, changeset_opts(parent, opts))
      |> Ash.Changeset.force_change_attribute(attr, new_value)
      |> Ash.update(update_opts(parent, opts))
    end
  end

  defp embedded_destroy(%parent{} = record, [attr | rest], action, params, opts)
       when is_atom(attr) do
    with %{type: type} <- attribute!(parent, attr),
         {:ok, new_value} <- destroy_in(type, Map.get(record, attr), rest, action, params, opts) do
      record
      |> Ash.Changeset.for_update(write_action(parent, opts), %{}, changeset_opts(parent, opts))
      |> Ash.Changeset.force_change_attribute(attr, new_value)
      |> Ash.update(update_opts(parent, opts))
    end
  end

  # ── locate + apply within the attribute value ─────────────────────────────

  # scalar embedded: the attribute value IS the instance
  defp apply_in(embedded, value, [], action, params, opts) when is_atom(embedded) do
    with {:ok, instance} <- instance(embedded, value, nil, opts) do
      run_embedded(instance, action, params, opts)
    end
  end

  # nested scalar path: descend into the instance's own embedded attribute
  defp apply_in(embedded, value, [next | _] = path, action, params, opts)
       when is_atom(embedded) and is_atom(next) do
    with {:ok, instance} <- instance(embedded, value, nil, opts) do
      fold_nested(embedded, instance, path, action, params, opts)
    end
  end

  # keyed array: locate by pk (insert-with-defaults on absent), pk-merge back
  defp apply_in({:array, embedded}, values, [{:item, key} | rest], action, params, opts) do
    values = List.wrap(values)
    pk_fields = Ash.Resource.Info.primary_key(embedded)
    index = Enum.find_index(values, &(pk_value(&1, pk_fields) == key))
    current = if index, do: Enum.at(values, index), else: nil

    result =
      with {:ok, instance} <- instance(embedded, current, {pk_fields, key}, opts) do
        case rest do
          [] ->
            run_embedded(instance, action, params, opts)

          [next | _] when is_atom(next) ->
            fold_nested(embedded, instance, rest, action, params, opts)
        end
      end

    with {:ok, new_instance} <- result do
      merged =
        if index,
          do: List.replace_at(values, index, new_instance),
          else: values ++ [new_instance]

      {:ok, merged}
    end
  end

  defp apply_in(_type, _value, path, _action, _params, _opts),
    do: {:error, {:unknown_target, path}}

  defp destroy_in(embedded, %embedded{} = value, [], action, params, opts)
       when is_atom(embedded) do
    with {:ok, _record} <- run_embedded_destroy(value, action, params, opts) do
      {:ok, nil}
    end
  end

  defp destroy_in(embedded, %embedded{} = value, [next | _] = path, action, params, opts)
       when is_atom(embedded) and is_atom(next) do
    with %{type: type} <- attribute!(embedded, next),
         {:ok, nested} <- destroy_in(type, Map.get(value, next), tl(path), action, params, opts) do
      {:ok, Map.put(value, next, nested)}
    end
  end

  defp destroy_in({:array, embedded}, values, [{:item, key}], action, params, opts) do
    values = List.wrap(values)
    pk_fields = Ash.Resource.Info.primary_key(embedded)

    case Enum.find_index(values, &(pk_value(&1, pk_fields) == key)) do
      nil ->
        {:error, {:unknown_target, key}}

      index ->
        value = Enum.at(values, index)

        with {:ok, _record} <- run_embedded_destroy(value, action, params, opts) do
          {:ok, List.delete_at(values, index)}
        end
    end
  end

  defp destroy_in({:array, embedded}, values, [{:item, key}, next | rest], action, params, opts)
       when is_atom(next) do
    values = List.wrap(values)
    pk_fields = Ash.Resource.Info.primary_key(embedded)

    case Enum.find_index(values, &(pk_value(&1, pk_fields) == key)) do
      nil ->
        {:error, {:unknown_target, key}}

      index ->
        value = Enum.at(values, index)

        with %{type: type} <- attribute!(embedded, next),
             {:ok, nested} <-
               destroy_in(type, Map.get(value, next), rest, action, params, opts) do
          {:ok, List.replace_at(values, index, Map.put(value, next, nested))}
        end
    end
  end

  defp destroy_in(_type, _value, path, _action, _params, _opts),
    do: {:error, {:unknown_target, path}}

  # nested chains: run the inner action, fold the changed struct outward —
  # still ONE parent update at the end
  defp fold_nested(owner, %_{} = instance, [attr | rest], action, params, opts)
       when is_atom(attr) do
    with %{type: type} <- attribute!(owner, attr),
         {:ok, new_value} <-
           apply_in(type, Map.get(instance, attr), rest, action, params, opts) do
      {:ok, Map.put(instance, attr, new_value)}
    end
  end

  # ── the instance's OWN action ──────────────────────────────────────────────

  defp run_embedded(%embedded{} = instance, action, params, opts) do
    instance
    |> Ash.Changeset.for_update(action, params, changeset_opts(embedded, opts))
    |> Ash.update(domain: domain(embedded), return_notifications?: true)
    |> action_record_result()
  end

  defp run_embedded_destroy(%embedded{} = instance, action, params, opts) do
    instance
    |> Ash.Changeset.for_destroy(action, params, changeset_opts(embedded, opts))
    |> Ash.destroy(
      domain: domain(embedded),
      return_destroyed?: true,
      return_notifications?: true
    )
    |> action_record_result()
  end

  # An absent key is created through the resource's own create action before
  # the addressed update runs. This preserves create defaults, changes,
  # validations, policies and hooks; only notification delivery is suppressed
  # because the single durable event is the enclosing parent update.
  defp instance(_embedded, %_{} = current, _pk, _opts), do: {:ok, current}
  defp instance(embedded, nil, nil, opts), do: create_embedded(embedded, %{}, opts)

  defp instance(embedded, nil, {pk_fields, key}, opts) do
    values =
      case {pk_fields, key} do
        {[field], key} -> [{field, key}]
        {fields, key} when is_tuple(key) -> Enum.zip(fields, Tuple.to_list(key))
      end

    create_embedded(embedded, Map.new(values), opts)
  end

  defp create_embedded(resource, input, opts) do
    action =
      Ash.Resource.Info.primary_action(resource, :create) ||
        Ash.Resource.Info.action(resource, :mount, :create)

    case action do
      %{name: name} ->
        accepted =
          Map.take(input, MapSet.to_list(Ash.Resource.Info.action_inputs(resource, name)))

        changeset =
          resource
          |> Ash.Changeset.for_create(name, accepted, changeset_opts(resource, opts))
          |> then(fn changeset ->
            Enum.reduce(input, changeset, fn {field, value}, changeset ->
              Ash.Changeset.force_change_attribute(changeset, field, value)
            end)
          end)

        changeset
        |> Ash.create(domain: domain(resource), return_notifications?: true)
        |> action_record_result()

      nil ->
        {:error, {:unknown_action, resource, :create}}
    end
  end

  defp action_record_result({:ok, record, _notifications}), do: {:ok, record}
  defp action_record_result({:ok, record}), do: {:ok, record}
  defp action_record_result({:error, error}), do: {:error, error}

  defp pk_value(instance, [field]), do: Map.get(instance, field)

  defp pk_value(instance, fields) when is_list(fields),
    do: fields |> Enum.map(&Map.get(instance, &1)) |> List.to_tuple()

  # ── plumbing ───────────────────────────────────────────────────────────────

  defp attribute!(resource, attr) do
    Ash.Resource.Info.attribute(resource, attr) ||
      {:error, {:unknown_target, attr}}
  end

  defp action_params(resource, action, params) do
    Map.take(params, MapSet.to_list(Ash.Resource.Info.action_inputs(resource, action)))
  end

  defp ensure_store_row(%resource{} = row, opts) do
    if match?(%{state: :loaded}, Map.get(row, :__meta__)) do
      {:ok, row}
    else
      case Ash.Resource.Info.action(resource, :mount, :create) do
        nil ->
          {:ok, row}

        action ->
          args =
            resource
            |> Ash.Resource.Info.action_inputs(action.name)
            |> MapSet.to_list()
            |> Map.new(&{&1, Map.get(row, &1)})
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)
            |> Map.new()

          changeset_opts =
            resource
            |> changeset_opts(opts)
            |> Keyword.put(:context, %{session_id: Map.get(row, :session_id)})
            |> Keyword.put(:upsert?, true)
            |> maybe_put_upsert_identity(resource)

          resource
          |> Ash.Changeset.for_create(:mount, args, changeset_opts)
          |> Ash.create(update_opts(resource, opts))
      end
    end
  end

  defp maybe_put_upsert_identity(opts, resource) do
    case Enum.find(Ash.Resource.Info.identities(resource), fn identity ->
           :session_id in List.wrap(Map.get(identity, :keys, []))
         end) do
      %{name: name} -> Keyword.put(opts, :upsert_identity, name)
      _none -> opts
    end
  end

  defp embedded_resource(resource, []), do: resource

  defp embedded_resource(resource, [attribute | rest]) when is_atom(attribute) do
    case Ash.Resource.Info.attribute(resource, attribute) do
      %{type: {:array, embedded}} -> embedded_resource(embedded, drop_item(rest))
      %{type: embedded} when is_atom(embedded) -> embedded_resource(embedded, rest)
    end
  end

  defp drop_item([{:item, _key} | rest]), do: rest
  defp drop_item(rest), do: rest

  defp write_action(resource, opts) do
    Keyword.get_lazy(opts, :write_action, fn ->
      case Ash.Resource.Info.primary_action(resource, :update) do
        %{name: name} -> name
        _none -> :update
      end
    end)
  end

  defp changeset_opts(resource, opts) do
    [
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant),
      domain: Keyword.get(opts, :domain, domain(resource)),
      authorize?: Keyword.get(opts, :authorize?, true),
      context: Keyword.get(opts, :context, %{})
    ]
  end

  defp update_opts(resource, opts) do
    [domain: Keyword.get(opts, :domain, domain(resource))]
  end

  defp domain(resource) do
    Ash.Resource.Info.domain(resource) || AshUi.AshDomainFallback
  end
end
