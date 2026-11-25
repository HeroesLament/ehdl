defmodule Hw.CLI.Project do
  @moduledoc """
  Running `ehdl` inside a Mix project.

  The installed `ehdl` carries its own copy of ehdl and knows nothing of a
  project's modules or dependencies. So in a directory with a `mix.exs` it
  does not do the work itself: it starts `mix run` there with the same
  arguments, and the project's own `Hw.CLI` (from its ehdl dependency) takes
  over with everything compiled and on the code path.
  """

  alias Hw.CLI

  @doc "True when this VM is already running under the project's Mix."
  @spec inside?() :: boolean()
  def inside? do
    Code.ensure_loaded?(Mix.Project) and Mix.Project.get() != nil
  end

  @doc "Re-run this command under the project's Mix, and exit with its status."
  @spec delegate() :: no_return()
  def delegate do
    mix = System.find_executable("mix") || CLI.fail!("mix.exs found but mix is not on PATH")

    # Compile as its own step: its output goes to stderr, so `-o -` can be
    # piped, and warnings from earlier compilations are not reprinted.
    case CLI.Exec.run(mix, ["compile", "--no-all-warnings"], stdout: :stderr) do
      0 -> :ok
      status -> System.halt(status)
    end

    run = ["run", "--no-compile", "--no-start", "-e", "Hw.CLI.main(System.argv())", "--"]
    System.halt(CLI.Exec.run(mix, run ++ CLI.argv()))
  end

  @doc "Every module of the project's own application."
  @spec modules() :: [module()]
  def modules do
    app = Mix.Project.config()[:app]
    Application.load(app)

    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      _ -> []
    end
  end
end
