# AshUi Phoenix

The Phoenix LiveView adapter for [AshUi](../../README.md).

It discovers the routed screens in your Ash domains and mounts each one
through a shared LiveView. For every screen it supplies the session, runs
bound actions, reloads rows on notifications, and sends minimal LiveView
diffs. The screens' UI structure and state stay in their resources.

```elixir
def deps do
  [
    {:ash_ui, "~> 0.1.0"},
    {:ash_ui_phoenix, "~> 0.1.0"}
  ]
end
```

Mount a domain's screens from the router:

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

Serve the client runtime (`phoenix.min.js`, `phoenix_live_view.min.js`, and
`ash_ui.min.js` under `/assets`) from your endpoint:

```elixir
plug AshUi.Phoenix.Assets
```

The host keeps its endpoint, PubSub, sessions, authentication, and other
static assets. Screens declare their addresses with `routes do` and mount
through their own `create :mount` action. Route and query values bind to
mount arguments by name.

## Authentication (optional)

The adapter doesn't require an authentication library. Without one, each
LiveView session carries the Ash tenant and context from the conn, and your
own `on_mount` hooks assign the actor.

To use [AshAuthentication](https://hexdocs.pm/ash_authentication_phoenix),
add `{:ash_authentication_phoenix, "~> 2.0"}` to your deps and enable the
preset. The adapter then resolves the signed-in user for every session, and
`ash_ui_authentication_routes/1` mounts the sign-in, sign-out and callback
routes:

```elixir
use AshUi.Phoenix.Router, presets: [AshUi.Phoenix.Presets.AshAuthentication]
```

See [DESIGN.md](../../DESIGN.md) §8 for the adapter contract.

## License

Apache License, Version 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
