defmodule Hw.CLI.Exec do
  @moduledoc """
  Runs another program on this terminal.

  The child inherits stdin, stdout and stderr, so a tool that draws a live
  progress line (oxibit, mix) still sees a terminal and draws it.
  """

  @doc """
  Run `exe` with `args` and return its exit status.

  `stdout: :stderr` sends the child's stdout to stderr, for a step whose
  chatter must not land in output the user may be piping.
  """
  @spec run(String.t(), [String.t()], keyword()) :: non_neg_integer()
  def run(exe, args, opts \\ []) do
    {exe, args} =
      case opts[:stdout] do
        :stderr -> {"/bin/sh", ["-c", ~s(exec "$@" 1>&2), "sh", exe | args]}
        _ -> {exe, args}
      end

    port = Port.open({:spawn_executable, exe}, [:nouse_stdio, :exit_status, args: args])

    receive do
      {^port, {:exit_status, status}} -> status
    end
  end
end
