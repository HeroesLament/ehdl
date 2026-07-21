defmodule Hw.Analysis.Location do
  @moduledoc """
  A source location captured at macro expansion time.

  Carried by every IR struct so that diagnostics can point precisely
  to where a signal, interface, instance, or connection was declared.

  Captured via `__ENV__` inside `use Hw.Component` macros — never
  constructed at runtime.
  """

  @type t :: %__MODULE__{
    file:   String.t(),
    line:   pos_integer(),
    column: pos_integer() | nil,
    module: module()
  }

  @enforce_keys [:file, :line, :module]
  defstruct [:file, :line, :column, :module]

  @doc """
  Build a Location from a Macro.Env struct.

  Call this inside any macro that wants to track where it was invoked:

      loc = Hw.Analysis.Location.from_env(__ENV__)
  """
  @spec from_env(Macro.Env.t()) :: t()
  def from_env(%Macro.Env{file: file, line: line, module: module}) do
    %__MODULE__{
      file:   file,
      line:   line,
      column: nil,
      module: module
    }
  end

  @doc """
  Format a location as a short human-readable string.

      iex> to_string(%Location{file: "lib/hw/usb/sie.ex", line: 31, module: Hw.USB.SIE})
      "lib/hw/usb/sie.ex:31"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{file: file, line: line, column: nil}) do
    "#{file}:#{line}"
  end

  def to_string(%__MODULE__{file: file, line: line, column: col}) do
    "#{file}:#{line}:#{col}"
  end

  @doc """
  Format just the filename (no directory) with line, for compact display.

      iex> short("lib/hw/usb/sie.ex", 31)
      "sie.ex:31"
  """
  @spec short(t()) :: String.t()
  def short(%__MODULE__{file: file, line: line}) do
    "#{Path.basename(file)}:#{line}"
  end
end
