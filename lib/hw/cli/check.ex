defmodule Hw.CLI.Check do
  @moduledoc "`ehdl check`: design analysis."

  use Cheer.Command

  alias Hw.Analysis
  alias Hw.CLI.Target

  command "check" do
    about "Run design analysis and report diagnostics"

    argument :design, help: "Design file or module [default: every design here]"
    option :warnings_as_errors, type: :boolean, help: "Exit 1 on warnings too"
    option :color, type: :boolean, default: true, help: "ANSI colour (--no-color to disable)"
  end

  @impl Cheer.Command
  def run(args, _raw) do
    target = Target.load(args[:design])

    case target.components ++ target.interfaces do
      [] ->
        IO.puts("no Hw.Component or Hw.Interface modules found")
        :ok

      modules ->
        report(modules, args)
    end
  end

  defp report(modules, args) do
    diagnostics = Analysis.run(modules).diagnostics |> promote(args[:warnings_as_errors])

    IO.write(:stderr, Analysis.Formatter.render(diagnostics, ansi: args[:color]))

    if Analysis.Diagnostic.has_errors?(diagnostics), do: {:error, 1}, else: :ok
  end

  defp promote(diagnostics, true) do
    Enum.map(diagnostics, fn
      %{severity: :warning} = d -> %{d | severity: :error}
      d -> d
    end)
  end

  defp promote(diagnostics, _), do: diagnostics
end
