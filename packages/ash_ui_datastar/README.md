# AshUi Datastar

A Plug adapter that serves [AshUi](../../README.md) screens over HTTP and
Server-Sent Events using [Datastar](https://data-star.dev).

It matches the screens' route declarations, creates or resumes the session's
row, runs bound actions, reloads rows on notifications, and sends the core's
differential updates as Datastar SSE events. It uses the same compiled
artifacts as the Phoenix adapter.

```elixir
def deps do
  [
    {:ash_ui, "~> 0.1.0"},
    {:ash_ui_datastar, "~> 0.1.0"}
  ]
end
```

Mount it in any Plug or Phoenix host:

```elixir
forward "/", AshUi.Datastar.Bridge, domains: [MyApp.Ui]
```

The host may pass `:session_id`, the actor and context, the tenant, or a mount
prefix in the bridge options. The screens' `routes do` declarations remain
the only source of routing.

See [DESIGN.md](../../DESIGN.md) §8 for the adapter contract.

## License

Apache License, Version 2.0. See [LICENSE](LICENSE). We bundle Datastar as
`priv/static/datastar.js` under its MIT license, which is reproduced in
[NOTICE](NOTICE).
