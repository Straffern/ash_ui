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

See [DESIGN.md](../../DESIGN.md) §8 for the adapter contract.

## License

Apache License, Version 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
