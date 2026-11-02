defmodule AshUi.Phoenix.Assets do
  @moduledoc """
  Plug for serving AshUi's client-side runtime assets.
  """

  @runtime_static_specs [
    {{:phoenix, "priv/static"}, "/assets", only: ["phoenix.min.js"]},
    {{:phoenix_live_view, "priv/static"}, "/assets", only: ["phoenix_live_view.min.js"]},
    {{:ash_ui_phoenix, "priv/static"}, "/assets", only: ["ash_ui.min.js"]}
  ]

  @spec runtime_static_specs() :: [{term(), String.t(), keyword()}]
  def runtime_static_specs, do: @runtime_static_specs

  def init(opts) do
    gzip = Keyword.get(opts, :gzip, false)

    @runtime_static_specs
    |> Enum.map(fn {from, at, static_opts} ->
      Keyword.merge(
        [
          at: at,
          from: from,
          gzip: gzip,
          raise_on_missing_only: false
        ],
        static_opts
      )
      |> Plug.Static.init()
    end)
  end

  def call(conn, static_plugs) do
    Enum.reduce_while(static_plugs, conn, fn static_opts, conn ->
      conn = Plug.Static.call(conn, static_opts)

      if conn.state in [:unset, :set] do
        {:cont, conn}
      else
        {:halt, conn}
      end
    end)
  end
end
