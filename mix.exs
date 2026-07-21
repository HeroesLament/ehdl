defmodule EHDL.MixProject do
  use Mix.Project

  def project do
    [
      app: :ehdl,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:prod), do: ["lib", "designs"]
  defp elixirc_paths(_),     do: ["lib", "designs"]

  defp deps do
    [
      {:elixir_scope, path: "../ex_dbg", optional: true, only: [:dev, :test]},
      {:rustler, "~> 0.37", runtime: false}
    ]
  end
end
