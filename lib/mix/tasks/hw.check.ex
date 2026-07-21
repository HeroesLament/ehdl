defmodule Mix.Tasks.Hw.Check do
  @moduledoc """
  Run hardware design analysis and report diagnostics.

      mix hw.check
      mix hw.check --no-color
      mix hw.check --modules Hw.USB.SIE,Hw.USB.CDCSerial

  Exits with status 1 if any errors are found, 0 otherwise.
  This makes it suitable for CI pipelines.

  ## Options

    * `--no-color` — disable ANSI colour output
    * `--modules` — comma-separated list of modules to check (default: all)
    * `--warnings-as-errors` — treat warnings as errors for exit code

  ## How it works

  `mix hw.check` runs after `mix compile`. It discovers all modules in
  the project that `use Hw.Component` or `use Hw.Interface`, collects
  their metadata (signals, interfaces, connections), runs the analysis
  rules, and reports diagnostics in a human-readable format.

  It does NOT re-compile anything — it operates purely on the compiled
  module metadata registered by the `use Hw.Component` macros.
  """

  use Mix.Task

  @shortdoc "Run hardware design analysis"

  @impl Mix.Task
  def run(args) do
    # Ensure the project is compiled first
    Mix.Task.run("compile", [])

    {opts, _rest, _invalid} = OptionParser.parse(args,
      strict: [
        no_color:           :boolean,
        modules:            :string,
        warnings_as_errors: :boolean
      ]
    )

    ansi = not Keyword.get(opts, :no_color, false)
    warnings_as_errors = Keyword.get(opts, :warnings_as_errors, false)

    modules = case Keyword.get(opts, :modules) do
      nil  -> discover_hw_modules()
      mods ->
        mods
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&Module.concat([&1]))
    end

    if modules == [] do
      Mix.shell().info("No Hw.Component or Hw.Interface modules found.")
    else
      Mix.shell().info("==> hw.check (#{length(modules)} modules)")

      result = Hw.Analysis.run(modules)

      diagnostics = if warnings_as_errors do
        Enum.map(result.diagnostics, fn d ->
          if d.severity == :warning, do: %{d | severity: :error}, else: d
        end)
      else
        result.diagnostics
      end

      output = Hw.Analysis.Formatter.render(diagnostics, ansi: ansi)
      IO.write(:stderr, output)

      if Hw.Analysis.Diagnostic.has_errors?(diagnostics) do
        Mix.raise("hw.check failed with errors.")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Module discovery
  # ---------------------------------------------------------------------------

  defp discover_hw_modules do
    # Load all beam files in the build path and find modules that
    # export __hw_signals__/0 (Hw.Component) or __hw_interface_signals__/0 (Hw.Interface)
    :code.all_loaded()
    |> Enum.map(fn {mod, _} -> mod end)
    |> Enum.filter(&hw_module?/1)
    |> Enum.sort()
  end

  defp hw_module?(module) do
    function_exported?(module, :__hw_signals__, 0) or
    function_exported?(module, :__hw_interface_signals__, 0)
  end
end
