defmodule AshUi.Phoenix.DesktopMenu do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :is_menu_server,
        persist: true,
        accumulate: false
      )

      Module.put_attribute(__MODULE__, :is_menu_server, true)

      @behaviour Desktop.Menu
      import Desktop.Menu, only: [assign: 2, assign: 3, assign_new: 3, connected?: 1]

      def render(assigns) do
        AshUi.Phoenix.DesktopMenu.render(__MODULE__, assigns)
      end
    end
  end

  def render(menu_module, assigns) do
    [
      "<menubar>",
      Enum.map(menu_module.menu_groups(assigns), &menu_group/1),
      "</menubar>"
    ]
    |> IO.iodata_to_binary()
  end

  defp menu_group(%{label: label, items: items}) do
    ["<menu label=\"", escape(label), "\">", Enum.map(items, &menu_item/1), "</menu>"]
  end

  defp menu_item(:separator), do: "<hr/>"

  defp menu_item(%{onclick: onclick, label: label}) do
    ["<item onclick=\"", escape(onclick), "\">", escape(label), "</item>"]
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
