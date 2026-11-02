defmodule AshUi.DefectClass.DC28TypedSurfaceTest do
  # F1/F2 (2026-07-09): AshUi resources declare no loose helpers and
  # no untyped public inputs.
  use ExUnit.Case, async: true

  test "public :map attribute without [opaque] is a located compile error" do
    source = """
    defmodule DC28.UntypedPage do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: :embedded,
        extensions: [AshUi],
        authorizers: [Ash.Policy.Authorizer]

      policies do
        policy always() do
          authorize_if(always())
        end
      end

      attributes do
        attribute(:blob, :map, public?: true)
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(section(:root, [], [])))
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end
    assert Exception.message(error) =~ "public :blob is untyped"
    assert Exception.message(error) =~ "embedded value resource"
  end

  test "a defp helper in an AshUi resource is a located compile error" do
    source = """
    defmodule DC28.HelperPage do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: :embedded,
        extensions: [AshUi],
        authorizers: [Ash.Policy.Authorizer]

      policies do
        policy always() do
          authorize_if(always())
        end
      end

      attributes do
        attribute(:label, :string, public?: true)
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(section(:root, [], [text(label)])))
      end

      actions do
        action :format_label, :string do
          argument(:label, :string, allow_nil?: false)
          run(fn input, _context -> {:ok, fancy_label(input.arguments.label)} end)
        end
      end

      defp fancy_label(label), do: label
    end
    """

    path =
      Path.join(System.tmp_dir!(), "dc28_helper_page_#{System.unique_integer([:positive])}.ex")

    File.write!(path, source)

    try do
      error = assert_raise Spark.Error.DslError, fn -> Code.compile_file(path) end
      assert Exception.message(error) =~ "private helper `fancy_label/1`"
      assert Exception.message(error) =~ "calculation"
    after
      File.rm(path)
    end
  end

  test "a rationale comment allowlists a helper" do
    source = """
    defmodule DC28.JustifiedHelperPage do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: :embedded,
        extensions: [AshUi],
        authorizers: [Ash.Policy.Authorizer]

      policies do
        policy always() do
          authorize_if(always())
        end
      end

      attributes do
        attribute(:label, :string, public?: true)
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree, expr(section(:root, [], [text(label)])))
      end

      actions do
        action :format_short_label, :string do
          argument(:label, :string, allow_nil?: false)
          run(fn input, _context -> {:ok, fancy_label(input.arguments.label)} end)
        end

        action :format_long_label, :string do
          argument(:label, :string, allow_nil?: false)
          run(fn input, _context -> {:ok, fancy_label(input.arguments.label)} end)
        end
      end

      # helper: fancy_label/1 — boundary adapter used by two actions
      defp fancy_label(label), do: label
    end
    """

    path = Path.join(System.tmp_dir!(), "dc28_ok_page_#{System.unique_integer([:positive])}.ex")
    File.write!(path, source)

    try do
      assert [_ | _] = Code.compile_file(path)
    after
      File.rm(path)
    end
  end
end

defmodule AshUi.DefectClass.DC28DispatchMapTest do
  # F4: event bindings name an ordinary action atom; dispatch carrier values
  # are not a second event model.
  use ExUnit.Case, async: true

  test "raw dispatch map raises with the native-form guidance" do
    error =
      assert_raise ArgumentError, fn ->
        AshUi.ViewConstructor.button(
          [on_click: %{kind: :dispatch, ui_event: :smuggled}],
          []
        )
      end

    assert Exception.message(error) =~ "expects a bare Ash action atom"
  end

  test "bare action atoms produce an event binding" do
    assert %{events: [%AshUi.EventBinding{ui_event: :open_pdf}]} =
             AshUi.ViewConstructor.button(
               [on_click: :open_pdf],
               []
             )
  end
end

defmodule AshUi.DefectClass.DC28PathRestrictionTest do
  # F3: path() over a typed value is a located compile error.
  use ExUnit.Case, async: true

  test "path() over a typed attribute errors toward the bare ref" do
    source = """
    defmodule DC28.PathDigPage do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: :embedded,
        extensions: [AshUi],
        authorizers: [Ash.Policy.Authorizer]

      policies do
        policy always() do
          authorize_if(always())
        end
      end

      attributes do
        attribute(:title, :string, public?: true)
      end

      calculations do
        calculate(:view, AshUi.Type.RenderTree,
          expr(section(:root, [], [text(path(title, [:anything]))])))
      end
    end
    """

    error = assert_raise Spark.Error.DslError, fn -> Code.compile_string(source) end
    assert Exception.message(error) =~ "digs a TYPED value"
    assert Exception.message(error) =~ "bare ref"
  end
end
