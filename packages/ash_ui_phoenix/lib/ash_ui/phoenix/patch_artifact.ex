defmodule AshUi.Phoenix.PatchArtifact do
  @moduledoc false

  @format_version 1
  @file_extension ".abp"
  @module_infix ".AshUiPhoenixPatchArtifact"

  @doc false
  def install(resource, tables, directory)
      when is_atom(resource) and is_map(tables) and is_binary(directory) do
    hash = blueprint_hash(resource)
    artifact = artifact_module(resource, hash)
    path = Path.join(directory, filename(artifact))

    payload =
      {:ash_ui_patch_artifact, @format_version, resource, hash, tables}
      |> :erlang.term_to_binary([:compressed])

    File.mkdir_p!(directory)
    temporary = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    try do
      File.write!(temporary, payload)
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end

    remove_stale_files(resource, path, directory)
    purge_legacy_modules(resource)
    path
  end

  @doc false
  def load(resource, view) when is_atom(resource) and is_atom(view) do
    hash = blueprint_hash(resource)
    artifact = artifact_module(resource, hash)

    case :code.where_is_file(filename(artifact) |> String.to_charlist()) do
      :non_existing ->
        nil

      path ->
        path
        |> File.read!()
        |> decode!(resource, hash)
        |> Map.get(view)
    end
  end

  @doc false
  def artifact_module(resource), do: artifact_module(resource, blueprint_hash(resource))

  @doc false
  def artifact_module(resource, hash) when is_atom(resource) do
    suffix =
      hash
      |> normalized_hash()
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    Module.concat(resource, "AshUiPhoenixPatchArtifact#{suffix}")
  end

  defp decode!(binary, resource, hash) do
    # This file is compiler output beside the application's BEAM files and has
    # the same executable trust boundary. Patch tables contain evaluator funs
    # and atoms from modules that may not be loaded yet, so `[:safe]` rejects a
    # valid artifact in a fresh VM.
    case :erlang.binary_to_term(binary) do
      {:ash_ui_patch_artifact, @format_version, ^resource, ^hash, tables}
      when is_map(tables) ->
        tables

      _other ->
        raise ArgumentError,
              "invalid AshUi patch artifact for #{inspect(resource)}"
    end
  end

  defp blueprint_hash(resource) do
    if Code.ensure_loaded?(resource) and
         function_exported?(resource, :__ash_ui_blueprint_hash__, 0) do
      resource.__ash_ui_blueprint_hash__()
    else
      :erlang.term_to_binary(:erlang.phash2(resource))
    end
  end

  defp normalized_hash(hash) when is_binary(hash) and byte_size(hash) >= 8, do: hash
  defp normalized_hash(hash), do: :crypto.hash(:sha256, :erlang.term_to_binary(hash))

  defp filename(artifact), do: Atom.to_string(artifact) <> @file_extension

  defp remove_stale_files(resource, current_path, directory) do
    prefix = Atom.to_string(resource) <> @module_infix

    for path <- Path.wildcard(Path.join(directory, prefix <> "*")),
        path != current_path,
        Path.extname(path) in [@file_extension, ".beam"] do
      File.rm!(path)
    end
  end

  defp purge_legacy_modules(resource) do
    prefix = Atom.to_string(resource) <> @module_infix

    for {module, _path} <- :code.all_loaded(),
        String.starts_with?(Atom.to_string(module), prefix) do
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    :ok
  end
end
