port = System.get_env("PORT", "7331") |> String.to_integer()
{:ok, _server} = Bandit.start_link(plug: AshUi.Datastar.SDKTestPlug, port: port)
IO.puts("Datastar SDK test bridge listening on #{port}")
Process.sleep(:infinity)
