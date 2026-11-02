defmodule AshUi.Attributes do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      import AshUi.Attributes

      Module.register_attribute(__MODULE__, :ash_ui_attribute_sets, accumulate: true)
      @before_compile AshUi.Attributes
    end
  end

  defmacro ash_ui(do: body) do
    entries = normalize_ash_ui_config!(body, __CALLER__)

    quote do
      (unquote_splicing(Enum.map(entries, &ash_ui_entry_ast/1)))
    end
  end

  defmacro attribute_set(name, do: body) when is_atom(name) do
    quote do
      @ash_ui_attribute_sets {unquote(name), unquote(Macro.escape(body))}
    end
  end

  defmacro include_attrs({module_ast, set_name}) when is_atom(set_name) do
    expanded_module = Macro.expand(module_ast, __CALLER__)

    body =
      case Code.ensure_compiled(expanded_module) do
        {:module, ^expanded_module} ->
          if function_exported?(expanded_module, :__ash_ui_attribute_set__, 1) do
            expanded_module.__ash_ui_attribute_set__(set_name)
          else
            raise ArgumentError,
                  "#{inspect(expanded_module)} does not define any AshUi attribute sets"
          end

        {:error, reason} ->
          raise ArgumentError,
                "could not compile #{inspect(expanded_module)} while including attribute set #{inspect(set_name)}: #{inspect(reason)}"
      end

    quote do
      unquote(body)
    end
  end

  defmacro __before_compile__(env) do
    sets =
      env.module
      |> Module.get_attribute(:ash_ui_attribute_sets)
      |> Enum.into(%{})

    quote do
      def __ash_ui_attribute_set__(name) when is_atom(name) do
        case unquote(Macro.escape(sets)) do
          %{^name => body} ->
            body

          _other ->
            raise ArgumentError,
                  "unknown AshUi attribute set #{inspect(name)} for #{inspect(__MODULE__)}"
        end
      end
    end
  end

  defp normalize_ash_ui_config!({:__block__, _meta, expressions}, caller),
    do: Enum.flat_map(expressions, &normalize_ash_ui_config!(&1, caller))

  defp normalize_ash_ui_config!({name, _meta, [value_ast]} = expression, caller)
       when name in [:strict_expressions?] do
    value = AshUi.Expr.Literal.eval!(value_ast, caller)
    [{:option, name, value, Spark.Dsl.Extension.macro_env_anno(caller, expression)}]
  rescue
    # broad rescue: config macros expose literal-evaluation failures as DSL authoring errors.
    _error ->
      raise ArgumentError,
            "ash_ui/#{name} expects a literal value, got: #{Macro.to_string(value_ast)}"
  end

  defp normalize_ash_ui_config!(
         {:stylesheets, _meta, [stylesheets_ast]} = expression,
         caller
       ) do
    stylesheets = AshUi.Expr.Literal.eval!(stylesheets_ast, caller)

    unless is_list(stylesheets) and Enum.all?(stylesheets, &is_binary/1) do
      raise ArgumentError,
            "ash_ui/stylesheets expects a literal list of strings, got: " <>
              Macro.to_string(stylesheets_ast)
    end

    [{:option, :stylesheets, stylesheets, Spark.Dsl.Extension.macro_env_anno(caller, expression)}]
  rescue
    # broad rescue: config macros expose literal-evaluation failures as DSL authoring errors.
    _error ->
      raise ArgumentError,
            "ash_ui/stylesheets expects a literal list of strings, got: " <>
              Macro.to_string(stylesheets_ast)
  end

  defp normalize_ash_ui_config!(other, _caller) do
    raise ArgumentError, "unsupported ash_ui config entry: #{Macro.to_string(other)}"
  end

  defp ash_ui_entry_ast({:option, key, value, anno}) do
    quote do
      Spark.Dsl.Extension.SectionOption.set_section_option(
        __MODULE__,
        AshUi,
        [:ash_ui],
        unquote(key),
        unquote(Macro.escape(value)),
        unquote(Macro.escape(anno))
      )
    end
  end
end
