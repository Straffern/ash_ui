defmodule AshUi.AssetBundleFreshnessTest do
  use ExUnit.Case, async: true

  @sources [
    "assets/js/boot.js",
    "assets/js/client.js",
    "assets/js/island.js",
    "assets/js/island_host.js",
    "assets/js/island_phoenix.js"
  ]
  @manifest "packages/ash_ui_phoenix/priv/static/ash_ui.min.js.sources.sha256"
  @rebuild_command "npx esbuild boot.js --bundle --minify --format=iife --global-name=AshUi --outfile=../../packages/ash_ui_phoenix/priv/static/ash_ui.min.js && node write_sources_sha256.mjs"
  test "platform bundle source-hash manifest matches its JavaScript sources" do
    root = Path.expand("..", __DIR__)
    manifest = Path.join(root, @manifest)
    expected = manifest |> File.read!() |> String.trim()
    actual = source_hash(root)

    assert actual == expected,
           "ash_ui_phoenix/priv/static/ash_ui.min.js source hash is stale.

Expected manifest: #{expected}
Current sources:   #{actual}

Rebuild it with:
  cd assets/js && #{@rebuild_command}
"
  end

  defp source_hash(root) do
    @sources
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn relative, context ->
      :crypto.hash_update(context, File.read!(Path.join(root, relative)))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
