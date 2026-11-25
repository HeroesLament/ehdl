defmodule Hw.CLI.Completions do
  @moduledoc "`ehdl completions`: shell completion scripts."

  use Cheer.Command

  @shells %{"bash" => :bash, "zsh" => :zsh, "fish" => :fish, "powershell" => :powershell}

  command "completions" do
    about "Print a shell completion script"

    argument :shell, required: true, choices: Map.keys(@shells), help: "Shell to generate for"
  end

  @impl Cheer.Command
  def run(%{shell: shell}, _raw) do
    IO.puts(Cheer.Completion.generate(Hw.CLI, Map.fetch!(@shells, shell), prog: "ehdl"))
    :ok
  end
end
