defmodule AshUi.Verifiers.StylesheetResolution do
  @moduledoc """
  Compile-time stylesheet resolution discipline (DESIGN.md §9).

  - A document-producing (routed) resource must have effective stylesheets:
    either locally declared via `ash_ui do stylesheets [...] end`, or
    SUPPLIED by a substrate extension through the supplier seam.
  - Supplied + locally declared is a conflict — one assembly channel only.
  - A non-routed (embedded/component) resource must not declare stylesheets;
    it is covered by the pages that mount it.

  ## The supplier seam

  A substrate extension's transformer supplies the effective stylesheets by
  persisting `{:ash_ui, :supplied_stylesheets}` with a list of paths:

      dsl_state
      |> Spark.Dsl.Transformer.persist(
        {:ash_ui, :supplied_stylesheets},
        ["platform/tokens.css", "skins/mail.css"]
      )

  When that marker is a list, it becomes the resource's effective stylesheet
  set (persisted as `:ash_ui_stylesheets` and returned by
  `AshUi.Info.stylesheets/1`); the resource must then declare none
  locally. There are no default stylesheets and no runtime fallbacks.
  """

  use Spark.Dsl.Verifier

  alias AshUi.Verifiers.Helpers
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    routed? = routed?(dsl_state)
    declared = declared_stylesheets(dsl_state)
    supplied = Verifier.get_persisted(dsl_state, {:ash_ui, :supplied_stylesheets}, nil)
    effective = Verifier.get_persisted(dsl_state, :ash_ui_stylesheets, []) || []

    cond do
      routed? and is_list(supplied) and declared != [] ->
        {:error,
         Helpers.dsl_error(
           dsl_state,
           [:ash_ui, :stylesheets],
           conflict_message(supplied, declared)
         )}

      routed? and effective == [] ->
        {:error, Helpers.dsl_error(dsl_state, [:ash_ui, :stylesheets], missing_message())}

      not routed? and declared != [] ->
        {:error,
         Helpers.dsl_error(
           dsl_state,
           [:ash_ui, :stylesheets],
           component_declares_message(declared)
         )}

      true ->
        :ok
    end
  end

  defp routed?(dsl_state) do
    case Verifier.get_persisted(dsl_state, :ash_ui_declared_routes, []) do
      routes when is_list(routes) -> routes != []
      _other -> false
    end
  end

  defp declared_stylesheets(dsl_state) do
    case Verifier.get_option(dsl_state, [:ash_ui], :stylesheets, []) do
      stylesheets when is_list(stylesheets) -> stylesheets
      _other -> []
    end
  end

  defp missing_message do
    """
    This AshUi resource declares routes but no stylesheets.

    A routed resource produces a document, and every document's paint must be
    declared data — otherwise there is no compile-time coverage contract for
    the parts it emits. Every document-producing resource must declare its
    stylesheets:

        ash_ui do
          stylesheets ["assets/css/theme.css", "assets/css/app.css"]
        end

    Each entry is both a compile-time build input (part coverage is verified
    against its [part=...] rules) and the served href (linked in declared
    order, resolved relative to the document base). There are no default
    stylesheets and no runtime fallbacks. Alternatively, a substrate extension
    may SUPPLY the effective stylesheets by persisting
    {:ash_ui, :supplied_stylesheets} from its transformer.
    See the ash_ui DESIGN.md §9.\
    """
  end

  defp conflict_message(supplied, declared) do
    """
    This AshUi resource declares stylesheets locally AND receives supplied
    stylesheets from a substrate extension.

    Supplied stylesheets exist so a substrate (for example an application shell) owns
    the document's paint as ONE assembly channel; a second, local declaration
    would create two competing import orders.

    Substrate supplied: #{inspect(supplied)}
    Locally declared:   #{inspect(declared)}

    Remove the local declaration and let the substrate supply the set:

        ash_ui do
          # no stylesheets here — the substrate persists
          # {:ash_ui, :supplied_stylesheets} for this resource
        end

    Or, if this resource should own its own paint, stop supplying stylesheets
    from the substrate extension and keep only the local declaration.
    See the ash_ui DESIGN.md §9.\
    """
  end

  defp component_declares_message(declared) do
    """
    This AshUi resource declares stylesheets but no routes.

    Only document-producing (routed) resources assemble a document, so only
    they declare stylesheets; an embedded/value component's parts are covered
    by the stylesheets of every page that mounts it.

    Declared here: #{inspect(declared)}

    Remove the declaration from this component and declare the sheets on the
    routed page(s) that render() it:

        # the routed page
        ash_ui do
          stylesheets ["assets/css/theme.css", "assets/css/app.css"]
        end

    See the ash_ui DESIGN.md §9.\
    """
  end
end
