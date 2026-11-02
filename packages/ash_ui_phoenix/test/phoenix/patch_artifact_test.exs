defmodule AshUi.Phoenix.PatchArtifactTest do
  use ExUnit.Case, async: false

  alias AshUi.Patch.Table
  alias AshUi.Phoenix.PatchArtifact

  defmodule Resource do
    def __ash_ui_blueprint_hash__, do: :binary.copy(<<2>>, 32)
  end

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    ets do
      private?(true)
    end

    attributes do
      attribute(:session_id, :string, primary_key?: true, allow_nil?: false, public?: false)
      attribute(:title, :string, allow_nil?: false, default: "Artifact", public?: true)
    end

    identities do
      identity(:session_instance, [:session_id], pre_check_with: AshUi.AshDomainFallback)
    end

    actions do
      defaults([:read, create: :*])
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(section(:root, [title: title], [text(title)]))
      )
    end
  end

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ash_ui_patch_artifact_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(directory)
    true = :code.add_patha(String.to_charlist(directory))

    on_exit(fn ->
      :code.del_path(String.to_charlist(directory))
      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "installs an external artifact and loads it without an artifact module", %{
    directory: directory
  } do
    table =
      AshUi.Patch.Compiler.compile(Page,
        target: AshUi.Phoenix.RenderTarget
      )

    path = PatchArtifact.install(Page, %{view: table}, directory)

    assert Path.extname(path) == ".abp"
    assert File.stat!(path).size > 0
    assert PatchArtifact.load(Page, :view) == table
    refute Code.ensure_loaded?(PatchArtifact.artifact_module(Page))
  end

  test "installing a new generation purges and deletes old loaded generations", %{
    directory: directory
  } do
    old_artifact = PatchArtifact.artifact_module(Resource, :binary.copy(<<1>>, 32))
    new_artifact = PatchArtifact.artifact_module(Resource)

    for artifact <- [old_artifact, new_artifact] do
      Module.create(
        artifact,
        quote do
          def table(:view), do: :legacy_literal
        end,
        Macro.Env.location(__ENV__)
      )

      assert :code.is_loaded(artifact) != false
    end

    PatchArtifact.install(Resource, %{view: %Table{resource: Resource}}, directory)

    assert :code.is_loaded(old_artifact) == false
    assert :code.is_loaded(new_artifact) == false
  end
end
