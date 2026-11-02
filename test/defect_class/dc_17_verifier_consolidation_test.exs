defmodule AshUi.DefectClass.DC17VerifierConsolidationTest do
  use ExUnit.Case, async: false

  @verifiers [
    AshUi.Verifiers.AuthoringSurfaceV3,
    AshUi.Verifiers.ExplicitSessions,
    AshUi.Verifiers.NoLooseHelpers,
    AshUi.Verifiers.TypedInputs,
    AshUi.Verifiers.NoExprSetAttribute,
    AshUi.Verifiers.VerifyExpressions,
    AshUi.Verifiers.SurfaceContracts,
    AshUi.Verifiers.StylesheetResolution,
    AshUi.Verifiers.StylesheetCoverage
  ]
  @broad_rescue_allowlist [
    {"lib/ash_ui/verifiers/no_loose_helpers.ex", :module_source},
    # Notification substrate (2026-07-09 core fixes): a malformed
    # subscription filter must not abort batch delivery.
    {"lib/ash_ui/patch/compiler.ex", :keyed_item_deps},
    {"lib/ash_ui/notification/match_index.ex", :safe_stage2_hit?},
    {"lib/ash_ui/attributes.ex", :normalize_ash_ui_config!},
    {"lib/ash_ui/expr/eval.ex", :eval},
    {"lib/ash_ui/expr/eval.ex", :evaluate_capability},
    {"lib/ash_ui/expr/eval.ex", :capability_allowed?},
    {"lib/ash_ui/expr/eval.ex", :domain_capability_allowed?},
    {"lib/ash_ui/expr/literal.ex", :eval!},
    # Reload-contract dependency index: declaration walkers over arbitrary
    # expressions and user calc modules degrade to the conservative
    # dependency instead of aborting a dispatch.
    {"lib/ash_ui/reload.ex", :expression_dep},
    {"lib/ash_ui/reload.ex", :module_calculation_dep},
    {"lib/ash_ui/runtime/errors.ex", :normalize_invoke_error},
    {"lib/ash_ui/runtime/resource_info.ex", :static_blueprint_module?},
    {"lib/ash_ui/runtime/view_render.ex", :render_view_node},
    {"lib/ash_ui/runtime/view_render.ex", :evaluate_value},
    {"lib/ash_ui/safe_html.ex", :normalize},
    {"lib/ash_ui/verifiers/strict_after_verify.ex", :run_verifier}
  ]
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

  test "contract verifiers run once per module compile" do
    page = unique_module([SingleVerifierPassPage])
    ref = make_ref()
    previous = Application.get_env(:ash_ui, :verifier_invocation_counter)
    Application.put_env(:ash_ui, :verifier_invocation_counter, {self(), ref})

    try do
      Code.compile_string("defmodule #{inspect(page)} do
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
    calculate(:view, AshUi.Type.RenderTree, expr(text(\"ok\")))
  end
end
")
    after
      restore_env(:verifier_invocation_counter, previous)
    end

    counts =
      ref
      |> drain_invocations()
      |> Enum.filter(fn {module, _verifier} -> module == page end)
      |> Enum.frequencies_by(fn {_module, verifier} -> verifier end)

    assert counts == Map.new(@verifiers, &{&1, 1})
  end

  test "located error for deleted read accessor" do
    page = unique_module([UnknownReadPage])
    error = assert_compile_dsl_error(page, "defmodule #{inspect(page)} do
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
    calculate(:view, AshUi.Type.RenderTree, expr(text(read(:missing_read))))
  end
end
")
    assert_located(error, page, ["view", "calculations"])
    assert Exception.message(error) =~ "unknown expression call read/1"
  end

  test "located error for deleted export accessor" do
    page = unique_module([UnknownExportPage])
    error = assert_compile_dsl_error(page, "defmodule #{inspect(page)} do
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
    calculate(:view, AshUi.Type.RenderTree, expr(text(export(:missing_export))))
  end
end
")
    assert_located(error, page, ["view", "calculations"])
    assert Exception.message(error) =~ "unknown expression call export/1"
  end

  test "located compile error for deleted path_for accessor" do
    page = unique_module([DeletedPathForPage])

    error =
      assert_compile_dsl_error(page, "defmodule #{inspect(page)} do
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

  attributes do
    attribute :artist_id, :string, public?: true
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text(path_for(DeletedApp, :show, %{id: artist_id}))))
  end
end
")

    assert_located(error, page, "view")
    assert Exception.message(error) =~ "path_for is not supported"
    assert Exception.message(error) =~ "link(to: path) or a route location expression"
  end

  test "located did-you-mean error for statically known read field shape" do
    artist = unique_module([Artist])
    page = unique_module([BadReadFieldPage])
    error = assert_compile_dsl_error(page, "defmodule #{inspect(artist)} do
  use Ash.Resource,
    domain: nil,
    data_layer: :embedded, validate_domain_inclusion?: false

  attributes do
    attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :name, :string
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  actions do
    defaults [:read]
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

  relationships do
    has_one :selected_artist, #{inspect(artist)} do
      no_attributes? true
      read_action :read
    end
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text(path(selected_artist, [:nam]))))
  end
end
")
    assert_located(error, page, "view")

    assert Exception.message(error) =~
             "path(selected_artist, [:nam]) - #{inspect(artist)} has no field :nam. Did you mean :name?"
  end

  test "located did-you-mean error for typed each item field shape" do
    artist = unique_module([EachArtist])
    page = unique_module([BadItemFieldPage])
    error = assert_compile_dsl_error(page, "defmodule #{inspect(artist)} do
  use Ash.Resource,
    domain: nil,
    data_layer: :embedded, validate_domain_inclusion?: false

  attributes do
    attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
    attribute :id, :integer, primary_key?: true, allow_nil?: false
    attribute :name, :string
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  actions do
    defaults [:read]
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

  attributes do
    attribute(:session_id, :string, allow_nil?: false, primary_key?: true, public?: false)
  end

  identities do
    identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
  end

  relationships do
    has_many :artists, #{inspect(artist)} do
      no_attributes? true
      read_action :read
    end
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(each(artists, :artist, [], [text(artist.nam)])))
  end
end
")
    assert_located(error, page, "view")

    assert Exception.message(error) =~
             "item(:artist, :nam) - #{inspect(artist)} has no field :nam. Did you mean :name?"
  end

  test "located error for deleted vocabulary node" do
    page = unique_module([VocabularyNodePage])
    error = assert_compile_dsl_error(page, "defmodule #{inspect(page)} do
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

  attributes do
    attribute :entries, {:array, :map}, default: []
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(%{
      kind: :vocabulary,
      vocabulary: SomeVocabulary,
      node: :collection,
      name: :entries,
      options: %{items: entries},
      children: []
    }))
  end
end
")
    assert_located(error, page, "view")
    assert Exception.message(error) =~ "unsupported view node"
  end

  test "located error for deferred-module boot verification failure" do
    page = unique_module([DeferredReadPage])
    missing_resource = unique_module([MissingRelationshipResource])
    Code.compile_string("defmodule #{inspect(page)} do
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
    has_many :deferred, #{inspect(missing_resource)} do
      no_attributes? true
      read_action :read
    end
  end

  calculations do
    calculate(:view, AshUi.Type.RenderTree, expr(text(\"deferred\")))
  end
end
")
    error = assert_raise Spark.Error.DslError, fn -> AshUi.verify_deferred!(page) end
    assert_located(error, page, "relationships -> deferred")

    assert Exception.message(error) =~
             "deferred module #{inspect(missing_resource)} is not loaded"
  end

  test "lib source files have only allowlisted documented broad rescues" do
    repo_root = Path.expand("../..", __DIR__)

    files =
      [
        Path.join(repo_root, "lib/ash_ui"),
        Path.join(repo_root, "packages/ash_ui_phoenix/lib")
      ]
      |> Enum.flat_map(fn root -> root |> Path.join("**/*.ex") |> Path.wildcard() end)
      |> Enum.sort()

    actual =
      files
      |> Enum.flat_map(fn file ->
        source = File.read!(file)
        relative = Path.relative_to(file, repo_root)
        broad_rescue_entries(source, relative)
      end)
      |> MapSet.new()

    expected = MapSet.new(@broad_rescue_allowlist)
    assert actual == expected

    for {relative, function} <- @broad_rescue_allowlist do
      source = File.read!(Path.join(repo_root, relative))

      assert function_source(source, function) =~ "broad rescue:",
             "#{relative}:#{function}/... is allowlisted but has no in-code broad rescue rationale"
    end
  end

  defp assert_compile_dsl_error(module, source) do
    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end
    assert Exception.message(error) =~ inspect(module)
    error
  end

  defp assert_located(error, module, path_fragment) do
    message = Exception.message(error)
    assert message =~ inspect(module)
    assert Enum.any?(List.wrap(path_fragment), &String.contains?(message, &1))
  end

  defp unique_module(parts) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    Module.concat([__MODULE__ | parts] ++ [suffix])
  end

  defp restore_env(key, nil) do
    Application.delete_env(:ash_ui, key)
  end

  defp restore_env(key, value) do
    Application.put_env(:ash_ui, key, value)
  end

  defp drain_invocations(ref, acc \\ []) do
    receive do
      {^ref, :verifier_invoked, module, verifier} ->
        drain_invocations(ref, [{module, verifier} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp broad_rescue_entries(source, relative) do
    lines = String.split(source, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.reduce({nil, []}, fn {line, index}, {rescue_indent, entries} ->
      cond do
        is_nil(rescue_indent) and inline_broad_rescue_line?(line) ->
          {nil, [{relative, enclosing_function(lines, index)} | entries]}

        is_nil(rescue_indent) and rescue_line?(line) ->
          {indent_width(line), entries}

        not is_nil(rescue_indent) and end_line?(line, rescue_indent) ->
          {nil, entries}

        not is_nil(rescue_indent) and broad_rescue_line?(line) ->
          {rescue_indent, [{relative, enclosing_function(lines, index)} | entries]}

        true ->
          {rescue_indent, entries}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp broad_rescue_line?(line) do
    String.match?(line, ~r/^\s*(?:_|_?[a-z][a-zA-Z0-9_?!]*)\s*->/)
  end

  defp inline_broad_rescue_line?(line) do
    String.match?(line, ~r/\brescue\s+(?:_|_?[a-z][a-zA-Z0-9_?!]*)\s*->/)
  end

  defp rescue_line?(line) do
    String.match?(line, ~r/^\s*rescue(?:\s+.*)?$/)
  end

  defp end_line?(line, rescue_indent) do
    String.match?(line, ~r/^\s*end\b/) and indent_width(line) <= rescue_indent
  end

  defp indent_width(line) do
    line |> String.length() |> Kernel.-(String.length(String.trim_leading(line)))
  end

  defp enclosing_function(lines, line_no) do
    lines
    |> Enum.take(line_no)
    |> Enum.reduce(nil, fn line, current ->
      case Regex.run(~r/^\s*defp?\s+([a-zA-Z_][a-zA-Z0-9_?!]*)/, line) do
        [_full, function] -> String.to_atom(function)
        _other -> current
      end
    end)
  end

  defp function_source(source, function) do
    lines = String.split(source, "\n")

    function_lines =
      lines
      |> Enum.with_index()
      |> Enum.flat_map(fn {line, index} ->
        if function_def_line?(line, function) do
          lines |> Enum.drop(index) |> current_clause_lines()
        else
          []
        end
      end)

    assert function_lines != [], "function #{function} not found"
    function_lines |> Enum.join("\n")
  end

  defp function_def_line?(line, function) do
    String.match?(
      line,
      ~r/^\s*defp?\s+#{Regex.escape(Atom.to_string(function))}(?:\s|\()/
    )
  end

  defp current_clause_lines(lines) do
    end_offset =
      lines
      |> Enum.drop(1)
      |> Enum.find_index(fn line -> String.match?(line, ~r/^\s*defp?\s+[a-zA-Z_]/) end)

    Enum.take(lines, (end_offset || length(lines) - 1) + 1)
  end
end
