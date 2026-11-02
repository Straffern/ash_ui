defmodule AshUi.DefectClass.NoProcessDictTest do
  use ExUnit.Case, async: true
  @repo_root Path.expand("../..", __DIR__)
  @allowed_process_dict_files []
  test "lib/ash_ui does not use Process put/get outside profiling" do
    violations =
      @repo_root
      |> Path.join("lib/ash_ui/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, @repo_root))
      |> Enum.reject(&(&1 in @allowed_process_dict_files))
      |> Enum.flat_map(fn file ->
        source = File.read!(Path.join(@repo_root, file))

        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_no} -> line =~ ~r/Process\.(put|get)\b/ end)
        |> Enum.map(fn {line, line_no} -> "#{file}:#{line_no}:#{String.trim(line)}" end)
      end)

    assert violations == []
  end
end
