defmodule Hw.CLI do
  @moduledoc """
  The `ehdl` command line.

      ehdl emit blinky.ex            # blinky.v
      ehdl build blinky.ex --load    # blinky.v, then oxibit build --load
      ehdl check                     # design analysis
      ehdl census top.json           # netlist census against a device budget
      ehdl diagram blinky.ex         # wiring diagram
      ehdl completions zsh

  A design is named either by a source file or, inside a Mix project, by a
  module. See `Hw.CLI.Target`.

  Installed as an escript: `mix escript.install` from the ehdl checkout puts
  `ehdl` in `~/.mix/escripts`.
  """

  use Cheer.Command

  defmodule Error do
    @moduledoc "A failure with a message for the user and no stack trace."
    defexception [:message, code: 1]
  end

  @version Mix.Project.config()[:version]

  command "ehdl" do
    about "Elixir HDL: emit Verilog and build bitstreams from Hw.Component designs"
    version @version

    subcommand Hw.CLI.Emit
    subcommand Hw.CLI.Build
    subcommand Hw.CLI.Check
    subcommand Hw.CLI.Census
    subcommand Hw.CLI.Diagram
    subcommand Hw.CLI.Snapshot
    subcommand Hw.CLI.Completions
  end

  @doc "Escript entry point. Runs the command and halts with its exit code."
  def main(argv) do
    :persistent_term.put({__MODULE__, :argv}, argv)
    System.halt(run_cli(argv))
  end

  @doc "The arguments `main/1` was started with."
  def argv, do: :persistent_term.get({__MODULE__, :argv}, [])

  @doc "Stop the command with `message` on stderr and exit code 1."
  @spec fail!(String.t()) :: no_return()
  def fail!(message), do: raise(Error, message: message)

  defp run_cli(argv) do
    case Cheer.run(__MODULE__, argv, prog: "ehdl") do
      {:error, code} when is_integer(code) -> code
      result -> Cheer.exit_code(result)
    end
  rescue
    e in Error ->
      IO.puts(:stderr, "error: " <> e.message)
      e.code

    e ->
      IO.puts(:stderr, "error: " <> Exception.message(e))

      if System.get_env("EHDL_TRACE") do
        IO.puts(:stderr, Exception.format_stacktrace(__STACKTRACE__))
      end

      1
  end
end
