defmodule AshUi.MixProject do
  use Mix.Project

  @source_url "https://github.com/hyperbob-labs/ash_ui"

  def project do
    [
      app: :ash_ui,
      version: "0.1.0",
      elixir: "~> 1.19",
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AshUi.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ash, "~> 3.36"},
      {:spark, "~> 2.4 and >= 2.4.1"},
      {:jason, "~> 1.2"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:simple_sat, "~> 0.1", only: :test}
    ]
  end

  defp description do
    "User interfaces built from Ash resources: a screen is a resource with a row per session."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      maintainers: ["bob@hyperbob.ai"],
      files: [
        "lib",
        ".formatter.exs",
        "mix.exs",
        "README*",
        "CHANGELOG*",
        "LICENSE*",
        "NOTICE*",
        "DESIGN.md"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      assets: %{"images" => "images"},
      extras: ["README.md", "DESIGN.md", "CHANGELOG.md", "LICENSE", "NOTICE"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
