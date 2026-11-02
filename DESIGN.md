# AshUi Design

We treat this document as the contract for AshUi. Its section numbers are
cited in our compile-time errors.

## 1. The idea

Everything a user interface needs is already modeled by Ash. On a resource
you declare typed state, identity, relationships to other data, calculations
that derive values, actions that change state under validations and
policies, and notifications for when state changes. Those are the parts of
a UI model. In most UI frameworks they are rebuilt as a second system next
to the domain: components with local state, props, stores, event handlers,
subscriptions, and form objects.

We don't build a second system. We add one idea to Ash:

**You model a screen as a resource, and each session gets its own row.**

From that:

| UI concept | In AshUi |
|---|---|
| Screen or component state | Attributes on the screen's row |
| Data shown on screen | Relationships, aggregates, and calculations on the row |
| View | The row's `:view` calculation |
| Event | An action on the row |
| Reactivity | Notification → reload the row → recalculate the view |
| Component | Another resource, placed with `render/2` |
| Form | Controls bound to action arguments |
| Route | A declaration that binds URL parameters to mount arguments |
| Authorization | The resource's policies, applied to reads, actions, and the view |

You write the screen as a presentation model. You place it next to the
domain as a peer and relate it to domain resources through ordinary
relationships. You never generate it from the domain.

When you author UI, you use no concepts that are not Ash. On our side, we
supply a Spark extension (routes, the view compiler, binding verifiers), a
compiled render artifact, a notifier, a session lifecycle, a theming
contract, and render-target adapters.

## 2. Screens, sessions, and storage

You build every piece of UI as a standard Ash resource. You vary only its
storage.

**Store-backed rows.** For a screen, use `Ash.DataLayer.Ets` with
`ets do private? false end`. Declare a session attribute and an identity
that scopes rows to the session:

```elixir
attributes do
  attribute :session_id, :uuid, allow_nil?: false, primary_key?: true
end

identities do
  identity :session_instance, [:session_id]
end
```

If you want one row per subject (one per conversation, say), add the
subject attributes to the identity:
`identity :session_instance, [:session_id, :conversation_id]`.

We pass `session_id` in through the changeset context. Our extension adds
its `SetSessionId` change to every create action of a resource that
declares `session_id`. If you add that change yourself, we raise a compile
error, because the session would be provisioned twice.

You mount a screen through its own `create :mount` action, which upserts
the session's row. We bind route and query parameters to mount arguments by
name. When the session's transport dies, we delete the session's rows from
a supervised registry.

**Embedded values.** With `data_layer: :embedded`, you store a resource's
state in an attribute of a parent row: a single value, or
`{:array, Embedded}` keyed by the embedded primary key. Ash's own embedded
cast semantics apply, so the embedded resource's actions and validations
are run when the parent attribute is updated.

Above the storage layer, you get the same behaviour from store-backed and
embedded resources: the same action surface, the same event semantics, the
same errors, and the same reactivity. Choose between them by scale and
lifetime. When you move state from one to the other, you change storage;
you don't rewrite anything.

Rows are created by actions, never by rendering. You keep state sparse: if
your users expand 12 folders in a tree of 10,000 nodes, you hold 12
expansion rows.

## 3. The view is a calculation

```elixir
calculate :view, AshUi.Type.RenderTree, expr(
  section(:conversation, [], [
    list(:messages, [], [
      each(messages, :message, [key: message.id], [
        item(:message_row,
          [state: [selected: message.id == selected_message_id],
           on_click: :select_message,
           action_input: %{id: message.id}],
          [text(message.body)])
      ])
    ])
  ])
)
```

With this one expression you do three jobs.

1. **You write the UI.** `section`, `list`, `item`, `each`, `text`, and the
   other constructors are functions we register with the expression
   compiler. With `messages` and `selected_message_id` you refer directly to
   the resource's own relationships and attributes. You don't learn a
   template language, and you never fetch data in a view.
2. **You declare the view's dependencies.** We walk the expression and find
   every field the view reads. From that set we decide what to load for the
   view and what to re-render after a change (§7).
3. **You publish a contract.** You call
   `Ash.calculate(row, :view, actor: actor)` under your policies. Your
   tests, agents, and background workers get the same tree your users'
   browsers get.

You have constructors for semantic HTML elements (`article`, `aside`,
`box`, `button`, `cell`, `checkbox`, `dialog`, `fieldset`, `footer`, `form`,
`header`, `heading`, `image`, `inline`, `input`, `item`, `label`, `link`,
`list`, `main`, `nav`, `option`, `paragraph`, `popover`, `radio`, `row`,
`section`, `select`, `table`, `textarea`, and others), plus `text`,
`fragment`, `nothing`, `each`, `render`, `island`, and `el`. For branches,
use Ash `if`. For keyboard filters, use `key`, and for typed event
payloads, use `event`.

### Expression evaluation

Every expression is evaluated by Ash. We bind the view scope, lower our
syntax to native Ash expressions, and hand them to Ash. We never
reimplement an operator in generated render code.

- You keep Ash's three-valued logic for `and`, `or`, and `not`: `not nil`
  is `nil`. We apply truthiness (nil and false are off) only at a render
  decision: an `if` condition, visibility, a conditional class, or a
  binding guard.
- When you write `left || fallback`, we read it as `default(left,
  fallback)`. You fall back on empty values (nil, `""`, `[]`,
  `%Ash.NotLoaded{}`, an empty fragment). You keep `false` as `false`. For a
  nil-only fallback, use `coalesce`.
- `if` arms are evaluated lazily. A dead arm is never evaluated.
- We lower `case` to native Ash conditionals, evaluate its subject once,
  and give you nil when nothing matches.

We ship the view helpers (`blank?`, `present?`, `empty?`, `nilif_blank`,
`join`, `count`, `sort_by`, `append_unique`, `find_by`, `field_errors`,
`default`, `to_string`, `humanize`, `relative_time`, `time_ago_in_words`,
`truncate`, `strip_prefix`) as Ash custom expressions. Custom expressions
are read from your application's compile-time config, so list the modules
from `AshUi.Expressions.canonical/0` under
`config :ash, :custom_expressions`.

## 4. Composition

You compose with `render(Module, input)` and nothing else. You write the
module as a standard resource. We evaluate its input in the parent and
cast it into the child.

**You pass fragments as values.** For a component that takes markup,
declare an attribute of type `AshUi.Type.RenderTree`, and write the
fragment inline at the call site:

```elixir
render(FormControl, %{label: "Name", control: input(:name, [value: name], [])})
```

We evaluate every expression where you wrote it. The fragment is evaluated
over the caller's state, and its bindings name the caller's actions. In the
child's view, you decide where the finished tree goes by placing the
attribute. You reuse data values, tree values, and resources, all by
function application. You don't need slots or callbacks.

**Addressable children and projections.** When you write a binding in a
child's own view, we run it on a child instance that can be addressed from
state: an embedded value reached through an attribute path, or a
store-backed row. If you feed `render/2` a computed value, you get a
projection, not state. When your users trigger one of a projection's own
actions, we report an ordinary unknown-target error.

## 5. Events are actions

You write a binding as a bare action name. We run that action on the
resource whose view declares the binding:

```elixir
item(:row, [on_click: :select_message, action_input: %{id: message.id}], [...])
```

Inside `each`, a binding you write in the page's view still runs a page
action. You take arguments from the entry, not a target.

We check every binding at compile time. You must name an action that
exists on the declaring resource. You must match each `action_input` field
and `event(:field)` marker to an argument of that action, and you may use
only fields that the event type's payload schema allows. You bind a form
control to the action argument with the same field name. For a plain
"store this value" event, use `update :x do accept [:x] end`. Declare an
argument only when your input differs from the attribute.

**You handle work on an entry in a page action.** Pass the entry's key as
a typed argument and call the domain through its code interface with
`scope: context`, so the same actor, tenant, and context are carried to the
domain action and its policies are run:

```elixir
button(:follow, [on_click: :follow_artist, action_input: %{artist_id: artist.id}],
  [text("Follow")])

update :follow_artist do
  argument :artist_id, :uuid, allow_nil?: false

  change fn changeset, context ->
    Ash.Changeset.before_action(changeset, fn changeset ->
      Music.follow_artist!(changeset.arguments.artist_id, scope: context)
      changeset
    end)
  end
end
```

To update an embedded entry, take the entry's primary key in the page
action and update the parent attribute. If your users act on a missing or
stale key, you get an action error. We never insert silently.

**We address bindings by their declaration.** We give each rendered binding
a key built from compiled addresses and entry keys. On dispatch, we walk
the compiled tables to find the declaration. We check that the element is
still reachable (a binding in a branch that is now off is stale), and we
evaluate the payload against the current row. We register no handlers and
keep no per-session binding store.

**You key entries by Ash identity.** If you give an explicit `key:`, we use
it. Otherwise we key a resource entry on its full primary key, and a plain
map on `:id`, then on its position.

**Errors.** When an action fails, your users see its Ash error on the page.
We route errors with a field path to the controls bound to that field name,
set `aria-invalid`, and render the message. We keep other errors as page
error state. You read the same errors with `errors()` and
`field_errors(:name)` if you want to place them yourself. We clear them on
the next successful dispatch. We never drop a dispatch error silently.

**DOM effects.** From a successful action you may request one of `focus`,
`scroll_into_view`, or `select_text` on one `id` or `part`, optionally
guarded by typed arguments:

```elixir
change scroll_into_view(part: :document_match, block: :center, when_arguments: [:anchor])
```

We run each effect once and never replay it on a render, notification, or
reload. If we can't resolve a `scroll_into_view` target, we wait up to ten
seconds for the content, then report the failure. We never fail silently.

## 6. Reactivity

On your domain resources, add `notifiers: [AshUi.Notifier]`. You declare a
screen's subscription by declaring its relationships. We match committed
changes against the relationships, aggregates, and calculations your
screens read.

We treat a notification only as a signal to reload. We reload the row as
the session's actor, and we take the reloaded row as the truth. With
`changed_addresses/3` we compare the old and new rows, including loaded
relationships, calculations, and aggregates, and get the set of view slots
to re-render. We treat a field that is loaded on neither side as unchanged,
and a field that is loaded on one side only as changed.

In this release we dispatch notifications on a single node only.

## 7. Differential rendering

In the core we work out what changed. In each render target we decide how
to send it.

We compile each resource's view into a patch table:

- **Slots.** Every dynamic position in the view: text, attribute chunks,
  branches, keyed lists, and child renders, each with a stable address and
  an evaluator.
- **Propagation.** A map from each field to the slots that read it.
- **Skeleton.** The static HTML between dynamic positions. We render the
  view once with sentinel values and split the output around them, so the
  statics match the full renderer byte for byte.
- **Event index.** Every element with bindings, with its `each` chain and
  branch conditions. We resolve dispatch through this index (§5).

When a change arrives, we run this pipeline: reload → changed fields →
propagation → changed slot addresses → re-evaluate only those slots → emit.
For unchanged slots we send nothing. We diff lists per keyed entry, so when
your users edit one row out of ten thousand, we send a patch for that row
only. We materialize the full view once, at mount.

We kept the `Rendered` and keyed comprehension structures identical to
Phoenix LiveView's, field for field, and we derived our diff kernel from
LiveView's (see NOTICE). In the Phoenix adapter we pass these structures to
LiveView unchanged, and in our test suite we check wire diffs against
LiveView's own client merge.

We maintain one full renderer. We use it for `Ash.calculate(:view)`,
static HTML, skeleton compilation, and per-element evaluation at runtime.

## 8. Routes, location, and render targets

**Routes.** You declare routes on the screen, and we bind URL parameters to
mount arguments by name:

```elixir
routes do
  route "/conversations/:conversation_id", query: [:tab]
end
```

**You get the location from the row.** When one of your actions changes a
route-bound attribute, we update the browser location to match, filled from
the current row. With an optional `location: expr(...)`, you declare where
the row's state should take your users. When you point it at another
screen's address, we navigate there:

```elixir
route "/artists/new",
  location: expr(if not is_nil(saved_artist_id), do: "/artists/" <> saved_artist_id)
```

**Links.** We classify each `link(to: path)` against the routes your host
serves. For a link to the screen's own route, we patch in place. For a link
to another served route, we mount that screen over the same connection and
keep the session. For any other link, we render a plain anchor.

**Render targets.** We never name a target in the core. To write a target,
implement the `AshUi.RenderTarget` behaviour and consume the compiled
artifacts. By default we use `AshUi.RenderTarget.Static`. In your host,
cache compiled tables by `{resource, view, target}`.

In the Phoenix adapter we do this:

1. **Mount.** We run the screen's `:mount` action with the session in the
   context, then render everything.
2. **Params.** We re-run the mount upsert with the new params and render
   the changed slots.
3. **Events.** We resolve the binding (§5), run the action, and render the
   changed slots. Then we update the location.
4. **Notifications.** We reload the row and render the changed slots.
5. **Lifecycle.** We tie the session to its transport. When the transport
   dies, we stop the session's processes and delete its rows.

In your host you own the endpoint, router, PubSub, and authentication, and
you choose which screen mounts at which route. You never add UI structure
there. You build shells, navigation, and notices as ordinary screens and
rows. For a transient notice, for example, you write a row with an expiry
time and filter on it in the view's read.

**JavaScript islands.** For behaviour that only a browser can provide, use
an island:

```elixir
island("chart", props: %{series: series}, on: [point_selected: :select_point])
```

You write `props` as an ordinary expression, so when it changes we patch
only the island's payload attribute. With `on:` you map island events to
actions on the declaring resource, and we check them as we check DOM
bindings. On the client, you mount the island with
`AshUi.registerIsland(name, {onProps, onDestroy})` and dispatch with
`AshUi.emitIsland(name, event, payload)`. We never patch the island's
children. Keep application state out of islands. For heavy runtimes such as
editors and PDF viewers, use an iframe and talk to the page through typed
`postMessage` envelopes.

## 9. Theming

You describe structure in views and paint it with stylesheets. On a view
node we emit a `part` attribute and ARIA-first state attributes
(`state: [selected: expr]` becomes `aria-selected`, and custom states become
`data-*`). If you put a `class` or `style` attribute on a view node, we
raise a compile error.

- **You declare stylesheets as data** on routed resources:
  `ash_ui do stylesheets ["assets/css/theme.css", "assets/css/app.css"] end`.
  We read each entry at compile time and serve it as an href, linked in the
  order you declared. You declare none on embedded components; the pages
  that render them cover them.
- **We check coverage at compile time.** Every part you emit anywhere in a
  routed page's render closure must match a `[part="…"]` rule in its
  stylesheets. We register stylesheets as external resources, so when you
  edit one, we recompile the resources that declare it. We reject
  `@import`, because you set the import order with the declared list alone.
- **A shell can supply stylesheets for you.** You can write a substrate
  transformer, for example for an application shell, that supplies
  stylesheets. If a resource both receives supplied stylesheets and
  declares its own, we raise a compile error.
- **You carry runtime theme state** (scheme, fonts, zoom) in the session
  context. In the adapter we stamp `data-theme`, font custom properties,
  and zoom on the document. You keep palettes in token stylesheets keyed on
  `:root[data-theme=…]`. When your users switch theme, we flip an
  attribute; we never relink or recompile.

With `AshUi.Theme.VSCode` you generate a token stylesheet from VS Code
colour-theme JSON at build time, and we check WCAG contrast while you do.
You use it only to generate stylesheets, never during rendering.

## 10. Deliberately absent

We left these concepts out on purpose. Each row names what you use
instead.

| Usual concept | What you use instead |
|---|---|
| Components as a separate kind of thing | Resources, embedded or store-backed |
| Props versus state | Attributes, relationships, and calculations |
| Slots, fills, scoped slots, outlets | `RenderTree` attributes holding caller-written fragments |
| Event handlers, callbacks, bubbling, forwarding | Bindings that name actions on the declaring resource |
| Form objects | Controls bound to action arguments by field name |
| Lifecycle hooks | `create :mount`, and session cleanup by the runtime |
| Stores and reducers | The row and its update actions |
| Topics and subscriptions | Relationship declarations |
| Presenters and view models | The screen resource itself |
| Imperative navigation | Route declarations and the location projection |
| DOM queries and refs | Typed event payloads stored in attributes |
| Class names and inline styles in views | `part` and state attributes painted by stylesheets |

## 11. Known limitations

- **Patch-table persistence.** In hosts, you compile and cache patch
  tables. In the core we fall back to recompiling when you supply no table,
  and in our resource transformer we don't yet persist tables at compile
  time. In production, always pass a cached table to render and dispatch.
- **Calculations on embedded rows.** We load calculations on rows reached
  through relationships for the view. We don't yet evaluate calculations on
  embedded attribute values at render time. In an embedded row's view, you
  may read stored attributes but not calculations.
- **Single-node notifications.** We don't yet dispatch notifications across
  nodes.
- **Module calculations load what you declare.** For a module-backed Ash
  calculation, declare nested fields explicitly (`load [artist: [:name]]`).
  With a bare `load [:artist]`, you may get only the relationship key.
