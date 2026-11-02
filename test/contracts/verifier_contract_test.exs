defmodule AshUi.Contracts.VerifierContractTest do
  use ExUnit.Case, async: false

  defp unique_module(parts) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    Module.concat([__MODULE__ | parts] ++ [suffix])
  end

  defp explicit_session_contract do
    """
      attributes do
        attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      end

      identities do
        identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
      end
    """
  end

  test "UI-only AshUi resources use stock ETS entities or embedded values" do
    resource = unique_module([StockEts])

    Code.compile_string("""
    defmodule #{inspect(resource)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      ets do
        private?(true)
      end

      ash_ui do
      end

      attributes do
        attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
      end

      identities do
        identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(text("ok")))
      end
    end
    """)

    invalid_resource = unique_module([NonEmbeddedSimple])

    invalid_source = """
    defmodule #{inspect(invalid_resource)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Simple,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      ash_ui do
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(text("bad")))
      end
    end
    """

    assert_raise Spark.Error.DslError,
                 ~r"AshUi resources must use `data_layer: Ash.DataLayer.Ets`",
                 fn -> Code.compile_string(invalid_source) end
  end

  test "explicit sessions verifier reports missing session_id with did-you-mean guidance" do
    page = unique_module([MissingSessionIdPage])

    source = """
    defmodule #{inspect(page)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      ets do
        private?(true)
      end

      ash_ui do
      end

      attributes do
        attribute(:sessionid, :string, allow_nil?: false, primary_key?: true, public?: false)
      end

      identities do
        identity(:session_instance, [:sessionid], pre_check_with: AshUi.AshDomainFallback)
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(text("bad")))
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end
    message = Exception.message(error)
    assert message =~ "must explicitly declare `attribute :session_id`"
    assert message =~ "Did you mean `sessionid`?"
  end

  test "explicit sessions verifier rejects a nil-able session_id" do
    page = unique_module([NilableSessionIdPage])

    source = """
    defmodule #{inspect(page)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      ets do
        private?(true)
      end

      ash_ui do
      end

      attributes do
        attribute(:id, :uuid, allow_nil?: false, primary_key?: true, public?: false)
        attribute(:session_id, :string, allow_nil?: true, public?: false)
      end

      identities do
        identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(text("bad")))
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end
    assert Exception.message(error) =~ "with `allow_nil?: false`"
  end

  test "event payload verifier rejects fields outside the bound event schema" do
    page = unique_module([UnknownEventPayloadPage])

    source = """
    defmodule #{inspect(page)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      ets do
        private?(true)
      end

      ash_ui do
      end

    #{explicit_session_contract()}

      actions do
        action :record_click, :map do
          argument(:shift, :boolean)
          run(fn _input, _context -> {:ok, %{}} end)
        end
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(button(:bad, [type: :button, on_click: :record_click, action_input: %{shift: event(:shiftKey)}], [text("bad")])))
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end
    assert Exception.message(error) =~ "event(:shiftKey) is not available for :click events"
  end

  test "relationship-backed read contracts accept read actions" do
    read_source = unique_module([ReadSource])
    read_page = unique_module([ReadPage])

    ok_source = """
    defmodule #{inspect(read_source)} do
      use Ash.Resource,
        domain: nil,
        data_layer: :embedded, validate_domain_inclusion?: false

      attributes do
        attribute :name, :string
      end

      actions do
        defaults [:read]
      end
    end

    defmodule #{inspect(read_page)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      ets do
        private?(true)
      end

      ash_ui do
      end

    #{explicit_session_contract()}

      relationships do
        has_one :ok, #{inspect(read_source)} do
          no_attributes? true
          read_action :read
        end
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(text("relationship read")))
      end
    end
    """

    assert Code.compile_string(ok_source) |> Enum.any?(&match?({^read_page, _}, &1))
  end

  test "tree-valued component attributes use the ordinary required-input contract" do
    shell = unique_module([SplitShell])
    missing_page = unique_module([MissingFragmentPage])

    source = """
    defmodule #{inspect(shell)} do
      use Ash.Resource,
        domain: nil,
        data_layer: :embedded,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      attributes do
        attribute(:page, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(box(:root, [], [page])))
      end
    end

    defmodule #{inspect(missing_page)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      ets do
        private?(true)
      end

      ash_ui do
      end

    #{explicit_session_contract()}

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(render(#{inspect(shell)}, %{})))
      end
    end
    """

    assert_raise Spark.Error.DslError, ~r"missing required params \[:page\]", fn ->
      Code.compile_string(source)
    end
  end

  test "value-resource render assignments enforce required and unknown params" do
    card = unique_module([Card])
    page = unique_module([BadCardPage])

    source = """
    defmodule #{inspect(card)} do
      use Ash.Resource,
        domain: nil,
        data_layer: :embedded,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      attributes do
        attribute :label, :string, allow_nil?: false, public?: true
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(text(label)))
      end
    end

    defmodule #{inspect(page)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      ets do
        private?(true)
      end

      ash_ui do
      end

    #{explicit_session_contract()}

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(render(#{inspect(card)}, %{extra: "bad"})))
      end
    end
    """

    assert_raise Spark.Error.DslError, ~r"missing required params \[:label\]", fn ->
      Code.compile_string(source)
    end
  end

  test "direct events fail compile-time verification when required action args are omitted" do
    page = unique_module([BadDirectEventArgsPage])

    source = """
    defmodule #{inspect(page)} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshUi],
        validate_domain_inclusion?: false

      ets do
        private?(true)
      end

      ash_ui do
      end

      actions do
        update :select do
          argument :id, :string, allow_nil?: false
          change set_attribute(:id, arg(:id))
        end
      end

      attributes do
        attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
        attribute :id, :string
      end

      identities do
        identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(button(:bad, [type: :button, on_click: :select], [text("bad")])))
      end
    end
    """

    assert_raise Spark.Error.DslError, ~r"missing required action args \[:id\]", fn ->
      Code.compile_string(source)
    end
  end

  test "removed section syntax is rejected" do
    for {label, form} <- [
          components: "components do\nend",
          outlets: "outlets do\nend",
          sources: "sources do\nend",
          reads: "reads do\nend",
          exports: "exports do\nend",
          route_state: "route_state do\nend"
        ] do
      page = unique_module([RemovedSection, label])

      source = """
      defmodule #{inspect(page)} do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Ets,
          extensions: [AshUi],
          validate_domain_inclusion?: false

        ets do
          private?(true)
        end

        ash_ui do
        end

      #{explicit_session_contract()}

        #{form}

        calculations do
          calculate(:view, AshUi.Type.RenderTree, expr(text("legacy")))
        end
      end
      """

      assert_raise CompileError, fn -> Code.compile_string(source) end
    end
  end
end
