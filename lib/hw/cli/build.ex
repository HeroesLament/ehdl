defmodule Hw.CLI.Build do
  @moduledoc "`ehdl build`: a design to a bitstream, through oxibit."

  use Cheer.Command

  alias Hw.CLI

  command "build" do
    about "Emit a design and build its bitstream with oxibit"

    argument :design, help: "Design file (blinky.ex) or, in a Mix project, module"
    option :top, value_name: "MODULE", help: "Top component, when the design has several"
    option :board, value_name: "BOARD", help: "Target board, as oxibit names it"
    option :constraints, value_name: "FILE", help: "Pin constraints (.lpf or .xdc)"
    option :out, short: :o, value_name: "FILE", help: "Bitstream file [default: <design>.bit]"
    option :load, type: :boolean, help: "Load the bitstream onto the board when built"
    option :force, type: :boolean, help: "Overwrite a Verilog file ehdl did not write"
    trailing_var_arg :oxibit, help: "Arguments after -- go to oxibit build as they are"
  end

  @impl Cheer.Command
  def run(args, _raw) do
    oxibit = oxibit()
    {_top, verilog} = CLI.Emit.emit(Map.take(args, [:design, :top, :force]))

    case CLI.Exec.run(oxibit, ["build", verilog | oxibit_args(args)]) do
      0 -> :ok
      status -> {:error, status}
    end
  end

  defp oxibit do
    System.get_env("OXIBIT") || System.find_executable("oxibit") ||
      CLI.fail!("oxibit is not on PATH (set OXIBIT to its path)")
  end

  defp oxibit_args(args) do
    List.flatten([
      value("--board", args[:board]),
      value("--constraints", args[:constraints]),
      value("--out", args[:out]),
      if(args[:load], do: ["--load"], else: []),
      args[:oxibit] || []
    ])
  end

  defp value(_flag, nil), do: []
  defp value(flag, value), do: [flag, value]
end
