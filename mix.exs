defmodule EHDL.MixProject do
  use Mix.Project

  def project do
    [
      app: :ehdl,
      version: "0.1.0",
      elixir: "~> 1.14",
      description: "Elixir HDL — a hardware description language embedded in Elixir.",
      source_url: "https://github.com/HeroesLament/ehdl",
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["MIT", "Apache-2.0"],
      links: %{"GitHub" => "https://github.com/HeroesLament/ehdl"},
      files: ~w(lib native mix.exs README.md LICENSE.md LICENSE-MIT LICENSE-APACHE)
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(_),     do: ["lib"]

  defp deps do
    [
      {:elixir_scope, path: "../ex_dbg", optional: true, only: [:dev, :test]},
      {:rustler, "~> 0.37", runtime: false}
    ]
  end
end
