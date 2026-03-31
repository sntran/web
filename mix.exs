defmodule Web.MixProject do
  use Mix.Project

  @version "0.2.0"
  @repo_url "https://github.com/sntran/web"

  def project do
    [
      app: :web,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex Metadata
      description: "Web API-compliant library for Elixir.",
      package: package(),

      # Docs
      name: "Web",
      source_url: @repo_url,
      docs: [
        main: "Web",
        extras: ["README.md"]
      ],
      test_coverage: [tool: ExCoveralls]
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
        "coveralls.html": :test
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:finch, "~> 0.16"},
      {:castore, "~> 1.0"},
      {:stream_data, "~> 1.0", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.14", only: :dev, runtime: false}
    ]
  end
end
