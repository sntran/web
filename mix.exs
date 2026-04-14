defmodule Web.MixProject do
  use Mix.Project

  @version "0.3.0"
  @repo_url "https://github.com/sntran/web"
  @description "A protocol-agnostic, zero-buffer suite of Web Standard APIs for Elixir."

  def project do
    [
      app: :web,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # Hex Metadata
      description: @description,
      package: package(),

      # Docs
      name: "Web",
      source_url: @repo_url,
      docs: [
        main: "Web",
        extras: ["README.md"]
      ],
      test_coverage: [tool: ExCoveralls],
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Web.Application, []}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      requirements: %{
        "erlang" => ">= 28.0.0"
      },
      links: %{
        "GitHub" => @repo_url,
        "JS Fetch Spec" => "https://fetch.spec.whatwg.org/"
      },
      maintainers: ["sntran"]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test,
        precommit: :test
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:finch, "~> 0.16"},
      {:castore, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:benchee, "~> 1.3", only: [:dev, :test]},
      {:stream_data, "~> 1.0", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.14", only: :dev, runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to ensure formatting is consistent before committing, you might run:
  #
  #     $ mix precommit
  #
  # See the documentation for `Mix` for more info on aliases.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      precommit: ["format", "credo --strict", "test --cover"]
    ]
  end
end
