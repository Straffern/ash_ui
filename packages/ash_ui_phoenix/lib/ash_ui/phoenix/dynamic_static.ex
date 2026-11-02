defmodule AshUi.Phoenix.DynamicStatic do
  @moduledoc false

  import Plug.Conn

  def init({module, function, args} = opts)
      when is_atom(module) and is_atom(function) and is_list(args),
      do: opts

  def init(specs), do: specs

  def call(conn, {module, function, args}) do
    module
    |> apply(function, args)
    |> call_static_specs(conn)
  end

  def call(conn, specs), do: call_static_specs(specs, conn)

  defp call_static_specs(specs, conn) do
    specs
    |> List.wrap()
    |> Enum.reduce_while(conn, fn spec, current_conn ->
      spec
      |> normalize_static_spec()
      |> maybe_call_static(current_conn)
      |> case do
        {:sent, sent_conn} -> {:halt, halt(sent_conn)}
        {:miss, missed_conn} -> {:cont, missed_conn}
      end
    end)
  end

  defp normalize_static_spec({from, at, only}) when is_binary(at), do: {from, at, only}
  defp normalize_static_spec({from, only}), do: {from, "/", only}
  defp normalize_static_spec(_spec), do: nil

  defp maybe_call_static(nil, conn), do: {:miss, conn}

  defp maybe_call_static({from, at, only}, conn) do
    before_state = {conn.state, conn.status, conn.resp_body}

    served_conn =
      Plug.Static.call(
        conn,
        Plug.Static.init(
          [
            at: at,
            from: from,
            gzip: false,
            raise_on_missing_only: false
          ]
          |> maybe_put_only(only)
        )
      )

    if {served_conn.state, served_conn.status, served_conn.resp_body} != before_state or
         served_conn.halted do
      {:sent, served_conn}
    else
      {:miss, conn}
    end
  end

  defp maybe_put_only(opts, :all), do: opts
  defp maybe_put_only(opts, nil), do: opts
  defp maybe_put_only(opts, only), do: Keyword.put(opts, :only, only)
end
