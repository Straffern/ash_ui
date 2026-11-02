defmodule AshUi.DefectClass.SingleInterpreterTest do
  use ExUnit.Case, async: false
  alias AshUi.Bench.Pages
  alias AshUi.RenderTarget.Html

  @repo_root Path.expand("../..", __DIR__)
  @runtime_eval_files ["lib/ash_ui/event_binding.ex"]
  @canonical_markers [
    :_arg,
    :_child,
    :_context,
    :_dom,
    :_errors,
    :_export,
    :_has_errors,
    :_index,
    :_item,
    :_part_id,
    :_path_for,
    :_read,
    :_read_status,
    :_ref,
    :_result,
    :_route_param,
    :_source,
    :_state_path
  ]
  test "runtime surfaces do not pattern match canonical marker tuples outside Expr.Eval" do
    marker_pattern =
      @canonical_markers
      |> Enum.map(&(&1 |> Atom.to_string() |> String.trim_leading(":") |> Regex.escape()))
      |> Enum.join("|")
      |> then(&Regex.compile!("{:(?:#{&1})"))

    files =
      @runtime_eval_files ++
        ((Path.wildcard(Path.join(@repo_root, "lib/ash_ui/runtime/**/*.ex")) ++
            Path.wildcard(Path.join(@repo_root, "lib/ash_ui/changes/**/*.ex")))
         |> Enum.map(&Path.relative_to(&1, @repo_root)))

    violations =
      files
      |> Enum.reject(&(&1 == "lib/ash_ui/expr/eval.ex"))
      |> Enum.flat_map(fn file ->
        source = File.read!(Path.join(@repo_root, file))

        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_no} -> Regex.match?(marker_pattern, line) end)
        |> Enum.map(fn {line, line_no} -> "#{file}:#{line_no}:#{String.trim(line)}" end)
      end)

    assert violations == []
  end

  test "Ash.calculate view boundary is byte-identical to the single render pipeline" do
    fixtures = [
      {Pages.RowsPage, Pages.row_attrs()},
      {Pages.EventsPage, Pages.events_attrs()}
    ]

    for {module, attrs} <- fixtures,
        target <- [AshUi.RenderTarget.Static] do
      record = Ash.Seed.seed!(module, Map.put(attrs, :session_id, Ash.UUID.generate()))

      {:ok, calculated_tree} =
        Ash.calculate(record, :view,
          authorize?: false,
          domain: AshUi.AshDomainFallback
        )

      {:safe, calculated_iodata} = Html.render_static(calculated_tree, target: target)

      {:ok, pipeline_tree} =
        AshUi.Runtime.Rendering.render_tree(
          AshUi.Runtime.ResourceInfo.compiled_resource(module),
          record,
          %{},
          []
        )

      {:safe, pipeline_iodata} = Html.render_static(pipeline_tree, target: target)

      assert IO.iodata_to_binary(calculated_iodata) == IO.iodata_to_binary(pipeline_iodata)
    end
  end

  test "the duplicate compiled renderer does not exist" do
    refute Code.ensure_loaded?(AshUi.Runtime.CompiledRender)
    refute Code.ensure_loaded?(AshUi.StaticCompile.Segments)
    refute Code.ensure_loaded?(AshUi.CompiledView)
  end
end
