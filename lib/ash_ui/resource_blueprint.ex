defmodule AshUi.ResourceBlueprint do
  @moduledoc """
  Normalized resource contract consumed by the runtime and adapters.

  `name` is retained as a stable alias of `id` .
  """

  @enforce_keys [
    :id,
    :module,
    :extensions,
    :data_layer,
    :attributes,
    :relationships,
    :actions,
    :calculations,
    :aggregates,
    :route,
    :view
  ]
  defstruct [
    :id,
    :name,
    :module,
    :domain,
    extensions: [],
    data_layer: nil,
    attributes: [],
    relationships: [],
    actions: [],
    calculations: [],
    aggregates: [],
    route: %{params: [], queries: [], states: []},
    deferred_checks: [],
    dynamic_map_props: [],
    client_drivers: [],
    stylesheets: [],
    view: nil,
    strict_expressions?: :strict,
    source: nil
  ]

  @type attribute :: %{
          required(:name) => atom(),
          required(:type) => atom(),
          required(:default) => term(),
          optional(:route) => map() | nil,
          required(:primary_key?) => boolean(),
          required(:required?) => boolean(),
          required(:public?) => boolean()
        }

  @type action :: %{
          required(:name) => atom(),
          required(:type) => atom(),
          required(:when_variant) => atom() | nil,
          required(:arguments) => [map()],
          required(:set) => [%{required(:field) => atom(), required(:expr) => Ash.Expr.t()}],
          required(:changes) => [map()]
        }

  @type relationship :: %{
          required(:name) => atom(),
          required(:type) => :belongs_to | :has_many | :has_one,
          required(:destination) => module(),
          required(:destination_kind) => :static,
          required(:destination_resource) => t() | nil,
          required(:source_attribute) => atom() | nil,
          required(:destination_attribute) => atom() | nil,
          required(:define_attribute?) => boolean() | nil,
          required(:attribute_type) => atom() | module() | nil,
          required(:allow_nil?) => boolean() | nil,
          optional(:read_action) => atom() | nil,
          optional(:filter) => term(),
          optional(:sort) => term(),
          optional(:limit) => integer() | nil,
          optional(:offset) => non_neg_integer() | nil,
          optional(:no_attributes?) => boolean(),
          optional(:required_parent_attrs) => [atom()]
        }

  @type calculation :: %{
          required(:name) => atom(),
          required(:type) => atom(),
          required(:constraints) => keyword(),
          required(:calculation) => module() | {module(), keyword()} | nil,
          required(:expr) => Ash.Expr.t() | nil,
          required(:allow_nil?) => boolean()
        }

  @type route :: %{
          required(:params) => [
            %{
              required(:name) => atom(),
              required(:type) => atom(),
              required(:default) => term()
            }
          ],
          required(:queries) => [%{required(:name) => atom(), required(:default) => term()}],
          required(:states) => [
            %{
              required(:name) => atom(),
              required(:type) => atom(),
              required(:param) => atom(),
              required(:constraints) => keyword(),
              required(:default) => term()
            }
          ]
        }

  @type t :: %__MODULE__{
          id: atom(),
          name: atom() | nil,
          module: module() | nil,
          domain: module() | nil,
          extensions: [module()],
          data_layer: module() | atom() | nil,
          attributes: [attribute()],
          relationships: [relationship()],
          actions: [action()],
          calculations: [calculation()],
          aggregates: [map()],
          route: route(),
          deferred_checks: [map()],
          dynamic_map_props: [map()],
          client_drivers: [atom() | String.t()],
          stylesheets: [String.t()],
          view: map() | nil,
          strict_expressions?: :off | :warn | :strict,
          source: term()
        }
end
