defmodule AshUi.Datastar.MaterializeParityTest do
  use ExUnit.Case, async: true

  alias AshUi.Datastar.{FragmentRender, RenderTarget}
  alias AshUi.Patch.Compiler
  alias AshUi.Rendered.Materialize

  defmodule Track do
    use Ash.Resource, domain: nil, data_layer: :embedded, validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:title, :string, allow_nil?: false, default: "", public?: true)
      attribute(:playing?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    actions do
      defaults([:read, create: :*, update: :*])
    end
  end

  defmodule Shell do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:label, :string, allow_nil?: false, default: "", public?: true)
      attribute(:content, AshUi.Type.RenderTree, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, create: :*])

      update :noop do
        accept([])
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:shell, [], [
            button(:shell_action, [on_click: :noop], [text(label)]),
            content
          ])
        )
      )
    end
  end

  defmodule TrackRow do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:title, :string, allow_nil?: false, default: "", public?: true)
      attribute(:playing?, :boolean, allow_nil?: false, default: false, public?: true)
    end

    actions do
      defaults([:read, create: :*])

      update :rename do
        accept([:title])
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          item(:track_row, [], [
            input(
              :track_input,
              type: :text,
              name: :title,
              value: title,
              on_input: :rename
            ),
            if playing? do
              inline(:playing, [], [text("playing")])
            else
              inline(:paused, [], [text("paused")])
            end
          ])
        )
      )
    end
  end

  defmodule Page do
    use Ash.Resource,
      domain: nil,
      data_layer: :embedded,
      extensions: [AshUi],
      validate_domain_inclusion?: false

    attributes do
      attribute(:id, :string, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:title, :string, allow_nil?: false, default: "", public?: true)
      attribute(:show_form?, :boolean, allow_nil?: false, default: true, public?: true)
      attribute(:tracks, {:array, Track}, allow_nil?: false, default: [], public?: true)
    end

    actions do
      defaults([:read, create: :*])

      update :rename do
        accept([:title])
      end
    end

    calculations do
      calculate(
        :view,
        AshUi.Type.RenderTree,
        expr(
          section(:page, [aria: %{busy: show_form?}], [
            render(Shell, %{
              label: title,
              content: box(:shell_content, [], [text(title)])
            }),
            if show_form? do
              box(:form_wrap, [], [
                input(
                  :title_input,
                  type: :text,
                  name: :title,
                  value: title,
                  on_input: :rename
                )
              ])
            else
              paragraph(:empty_form, [], [text("hidden")])
            end,
            list(:tracks, [], [
              each(tracks, :track, [key: track.id], [
                render(TrackRow, %{
                  id: track.id,
                  title: track.title,
                  playing?: track.playing?
                })
              ])
            ])
          ])
        )
      )
    end
  end

  test "algebra materialization is byte-identical to the semantic full render" do
    table = Compiler.table(Page, target: RenderTarget)

    for record <- [
          page(),
          page(%{show_form?: false}),
          page(%{
            title: "Renamed & retitled",
            tracks: [track("t2", "Second", true), track("t1", "First <edit>")]
          })
        ] do
      rendered = AshUi.Render.build(record, :all, table: table, target: RenderTarget)
      semantic_html = FragmentRender.full_render(record, table)
      algebra_html = rendered |> Materialize.to_iodata() |> IO.iodata_to_binary()

      assert semantic_html == algebra_html

      # ARIA booleans are tri-state strings; false must survive both shared
      # attribute pipelines instead of being lowered as an HTML boolean.
      assert semantic_html =~ ~s(aria-busy="#{record.show_form?}")

      assert semantic_html =~
               ~r/data-on:(?:click|input)="@post\(&#39;\/_ash_ui\/dispatch\//

      refute semantic_html =~ "data-bind="
      refute semantic_html =~ "data-ash-ui-binding"
    end
  end

  test "RenderTree-valued child inputs retain Datastar ids in differential materialization" do
    table = Compiler.table(Page, target: RenderTarget)
    record = page()
    {differential_html, _state} = FragmentRender.initial_render(record, table)
    full_html = FragmentRender.full_render(record, table)

    assert differential_html == full_html

    assert differential_html =~
             ~r/<div[^>]*id="bp-[^"]+"[^>]*part="shell_content"/
  end

  defp page(overrides \\ %{}) do
    struct(
      Page,
      Map.merge(
        %{
          id: "page",
          title: "Library",
          tracks: [track("t1", "First"), track("t2", "Second", true)]
        },
        overrides
      )
    )
  end

  defp track(id, title, playing? \\ false),
    do: struct(Track, %{id: id, title: title, playing?: playing?})
end
