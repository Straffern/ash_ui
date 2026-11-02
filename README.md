# AshUi

**Model your UI with Ash.** No more parallel vocabularies for the business
domain and your UI.

![Model your UI with Ash: a screen is a resource, and each session gets its own row. Each session row is rendered through the :view calculation into its own browser, clicks come back as actions on the row, and the screen reads a domain resource through a relationship and reloads on its notifications.](images/ash_ui.svg)

With AshUi you build user interfaces out of ordinary
[Ash](https://ash-hq.org/) resources.

You already have every part of a UI model in Ash. You give a resource typed
state, identity, relationships to the data you want to show, calculations
that derive values, actions that change state under validations and
policies, and notifications for when something changes. With AshUi, one
idea is added: **you model a screen as a resource, and you give each browser
session its own row.** You get everything else from that idea.

- You keep the screen's UI state (selection, draft text, open panels, sort
  order) in the row's attributes.
- You load the data on screen through the row's relationships, aggregates,
  and calculations.
- You write the view as the row's `:view` calculation.
- Your users trigger the row's actions when they click, type, or submit.
- When someone changes a related record, we reload the row and recalculate
  the view for every user looking at it.

You don't learn a component system, a template language, a store, an
event-handler layer, or any subscription wiring. You write Ash resources, and
you keep using the tools you already use on Ash resources: policies, code
interfaces, `Ash.calculate/3`, tests, and introspection.

## A screen

```elixir
defmodule MyApp.Ui.InboxScreen do
  use Ash.Resource,
    domain: MyApp.Ui,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshUi],
    authorizers: [Ash.Policy.Authorizer]

  ets do
    private? false
  end

  ash_ui do
    stylesheets ["priv/static/inbox.css"]
  end

  routes do
    route "/inbox"
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  # You get one row per browser session; we fill in session_id.
  attributes do
    attribute :session_id, :uuid, allow_nil?: false, primary_key?: true
    attribute :selected_id, :uuid, public?: true
    attribute :draft, :string, public?: true
  end

  identities do
    identity :session_instance, [:session_id]
  end

  # You declare what the screen shows; we subscribe the screen to it.
  relationships do
    has_many :messages, MyApp.Mail.Message do
      no_attributes? true
      sort inserted_at: :desc
    end
  end

  # You write the view as a calculation of the row.
  calculations do
    calculate :view, AshUi.Type.RenderTree, expr(
      section(:inbox, [], [
        list(:messages, [], [
          each(messages, :message, [key: message.id], [
            item(:message_row,
              [state: [selected: message.id == selected_id],
               on_click: :select,
               action_input: %{id: message.id}],
              [text(message.subject)])
          ])
        ]),
        form(:composer, [on_submit: :send_draft], [
          input(:draft_input,
            [value: draft,
             on_input: :edit_draft,
             action_input: %{draft: event(:value)}],
            []),
          button(:send, [type: :submit], [text("Send")])
        ])
      ])
    )
  end

  # Your users trigger these actions from the view.
  actions do
    defaults [:read]

    create :mount

    update :select do
      argument :id, :uuid, allow_nil?: false
      change set_attribute(:selected_id, arg(:id))
    end

    update :edit_draft do
      accept [:draft]
    end

    update :send_draft do
      require_atomic? false
      validate present(:draft)

      change fn changeset, context ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          MyApp.Mail.send_message!(changeset.data.draft, scope: context)
          Ash.Changeset.force_change_attribute(changeset, :draft, nil)
        end)
      end
    end
  end
end
```

You add one line to the domain resource so that we can refresh the screens
that read it:

```elixir
defmodule MyApp.Mail.Message do
  use Ash.Resource,
    domain: MyApp.Mail,
    data_layer: AshPostgres.DataLayer,
    notifiers: [AshUi.Notifier]

  # ...
end
```

This example is compiled and run in `test/readme_example_test.exs`.

## What you get from "a screen is a resource"

**You can see and test all UI state.** You declare UI state as typed
attributes on a row, so you read it, query it, and test it like any other
Ash data. You choose between a stored row and an embedded value for storage
reasons only; you don't change any behaviour by switching.

**You render under your policies.** You call
`Ash.calculate(screen, :view, actor: actor)` and get the same render tree
your users' browsers get. You decide what each actor can see with the same
actor, tenant, and policy rules you already use for queries.

**You find event mistakes at compile time.** You name an action with
`on_click: :select`, and we check at compile time that the resource
declaring the binding has that action. We also check every `action_input`
field and `event(:value)` marker against the action's arguments. At runtime
you get the action's own casts, validations, changes, and policies, and your
users see each error next to the field bound to it.

**You write no reactivity wiring.** You declare a relationship to load the
messages, and we use the same declaration to decide which notifications
concern the screen. When someone commits a write, we reload the row through
its relationships as the session's actor and recalculate the view. We treat
a notification only as a hint to reload; we rely on the reload for
correctness.

**You ship small patches.** We compile your view calculation into a patch
table and record which attributes and relationships each part of it reads.
When something changes, we re-evaluate only the slots that read it, and we
diff lists per keyed entry. With the Phoenix adapter, we send standard
LiveView diffs.

**You compose by function application.** You place another resource's view
with `render(Child, input)`. You pass markup as a value in an attribute of
type `AshUi.Type.RenderTree`. You don't need slots, emits, or callbacks.

**You get the URL from the row.** You bind route path and query parameters
to the mount action's arguments by name. When your actions change those
attributes, we update the browser location to match.

## Installation

```elixir
def deps do
  [
    {:ash_ui, "~> 0.1.0"},
    {:ash_ui_phoenix, "~> 0.1.0"}
  ]
end
```

The view helpers are implemented as Ash custom expressions, which are read
from your application's config at compile time, so list them there. Keep your list identical to `AshUi.Expressions.canonical/0`:

```elixir
config :ash,
  custom_expressions: [
    AshUi.Expressions.ToString,
    AshUi.Expressions.Humanize,
    AshUi.Expressions.RelativeTime,
    AshUi.Expressions.TimeAgoInWords,
    AshUi.Expressions.Truncate,
    AshUi.Expressions.StripPrefix,
    AshUi.Expressions.ClassJoin,
    AshUi.Expressions.Blank,
    AshUi.Expressions.Present,
    AshUi.Expressions.Empty,
    AshUi.Expressions.NilifBlank,
    AshUi.Expressions.Join,
    AshUi.Expressions.Count,
    AshUi.Expressions.SortBy,
    AshUi.Expressions.AppendUnique,
    AshUi.Expressions.FindBy,
    AshUi.Expressions.FieldErrors,
    AshUi.Expressions.Default
  ]
```

With Phoenix, mount every routed screen in a domain from your router:

```elixir
defmodule MyAppWeb.Router do
  use AshUi.Phoenix.Router, presets: []

  ash_ui_browser_pipeline()

  scope "/" do
    pipe_through :browser
    ash_ui_routes domains: [MyApp.Ui]
  end
end
```

Then serve the client runtime from your endpoint with
`plug AshUi.Phoenix.Assets`. You keep your endpoint, sessions,
authentication, and PubSub. We supply the mount, dispatch, and render path.

## Packages

| Package | Purpose |
|---|---|
| `ash_ui` | The Ash extension: view constructors, compile-time verification, patch tables, the differential render kernel, notifications, sessions, static HTML, theming |
| [`ash_ui_phoenix`](https://hexdocs.pm/ash_ui_phoenix) | Phoenix LiveView adapter: router, mount, dispatch, notification reloads, assets |
| [`ash_ui_datastar`](https://hexdocs.pm/ash_ui_datastar) | Plug and Server-Sent Events adapter for [Datastar](https://data-star.dev) |

We keep every render target out of the core. We build each adapter on the
same compiled artifacts.

## Design

Read [DESIGN.md](DESIGN.md) for the full contract: sessions, the view
calculation, events, reactivity, the renderer, routing, theming, and current
limitations.

## Status

We have released AshUi 0.1. We consider the authoring model stable. Expect
us to change the adapter APIs and some theming details before 1.0. We
dispatch notifications on a single node only.

## License

Apache License, Version 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). We
derived the render and diff algebra in `lib/ash_ui/diff.ex` and
`lib/ash_ui/rendered.ex` from Phoenix LiveView, under its MIT license, which
is reproduced in NOTICE.
