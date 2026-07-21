defmodule Hw.DSL.Primitives do
  @moduledoc """
  DSL primitives for hardware component definitions.

  These macros collect declarations into module attributes.
  They do NOT interpret or validate - that happens during elaboration.

  ## Submodules

  - `Declarations` - clock, input, output, wire, inout, memory, blackbox, tristate
  - `LogicBlocks` - on, comb, instance, interface, connect
  - `Parse` - Expression and statement parsing
  """

  defmacro __using__(_opts) do
    quote do
      import Hw.DSL.Primitives.Declarations
      import Hw.DSL.Primitives.LogicBlocks
    end
  end
end
