defmodule AshUi.ViewCalculation do
  @moduledoc false

  use Ash.Resource.Calculation

  alias AshUi.ViewConstructor

  @impl true
  def load(_query, _opts, _context) do
    # Relationship deps are NOT declared here: Ash's calc-dependency
    # loader force-selects each dep relationship's source_attribute even
    # for no_attributes?/manual relationships (has_many defaults it to
    # :id), which breaks every session-pk page. calculate/3 loads the
    # derived dep set itself through the plain load path — the one every
    # host uses — with lazy?: true so already-loaded values are reused.
    []
  end

  @impl true
  def calculate(records, opts, context) do
    resource = resource_module(opts, context)
    view = Keyword.get(opts, :view, :view)
    compiled = compiled_resource(resource, view)

    with {:ok, records} <- load_view_deps(records, resource, view, context) do
      # the public Ash.calculate(:view) contract renders THE SAME view the
      # bridges render: actor/tenant ride the calculation context, and a
      # caller-supplied error list reproduces a failed dispatch
      render_opts = [
        actor: context.actor,
        tenant: context.tenant,
        context: %{current_user: context.actor},
        errors: List.wrap(context.arguments[:errors] || [])
      ]

      Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
        case AshUi.Runtime.Rendering.render_tree(compiled, record, %{}, render_opts) do
          {:ok, tree} -> {:cont, {:ok, [tree | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, trees} -> {:ok, Enum.reverse(trees)}
        error -> error
      end
    end
  end

  defp load_view_deps(records, resource, view, context) do
    case view_exprs(resource) do
      %{^view => compiled} = exprs ->
        case ViewConstructor.load_spec(compiled, exprs, resource) do
          [] -> {:ok, records}
          loads -> load_missing(records, loads, context)
        end

      _other ->
        {:ok, records}
    end
  end

  # Load only what is actually %Ash.NotLoaded{} — values already present
  # (prior loads, or values placed by callers) are respected as loaded
  # truth, and skipping Ash's lazy?-stitching keeps this robust across
  # Ash versions and hand-shaped records.
  defp load_missing(records, loads, context) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      missing =
        Enum.filter(loads, fn
          {field, _nested} -> match?(%Ash.NotLoaded{}, Map.get(record, field))
          field when is_atom(field) -> match?(%Ash.NotLoaded{}, Map.get(record, field))
          _other -> false
        end)

      result =
        if missing == [] do
          {:ok, record}
        else
          Ash.load(record, missing,
            domain: Map.get(context, :domain) || AshUi.AshDomainFallback,
            actor: Map.get(context, :actor),
            tenant: Map.get(context, :tenant),
            authorize?: Map.get(context, :authorize?, true)
          )
        end

      case result do
        {:ok, loaded} -> {:cont, {:ok, [loaded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      error -> error
    end
  end

  defp compiled_resource(resource, view) do
    compiled = AshUi.Runtime.ResourceInfo.compiled_resource(resource)

    if view == :view do
      compiled
    else
      case view_exprs(resource) do
        %{^view => expr} -> %{compiled | view: ViewConstructor.lower(expr)}
        _other -> compiled
      end
    end
  end

  defp resource_module(opts, context) do
    Keyword.get(opts, :resource) ||
      Keyword.get(opts, :ash_resource_module) ||
      Map.get(context || %{}, :resource) ||
      Map.get(context || %{}, :resource_module)
  end

  defp view_exprs(resource) when is_atom(resource) do
    case AshUi.Compiled.view_exprs(resource) do
      %{} = exprs -> exprs
      _other -> %{}
    end
  end

  defp view_exprs(_resource), do: %{}
end
