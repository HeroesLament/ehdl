defmodule Hw.IR.Ops do
  @moduledoc """
  Hardware operations for IR.

  These are the "verbs" of the system - they describe what happens.
  Each op maps to exactly one piece of hardware. No hidden logic.

  ## Design Rules

  1. One struct = one semantic hardware primitive
  2. No "smart" ops that infer behavior
  3. Every op has explicit inputs and outputs
  4. If it would surprise a VHDL engineer, it doesn't belong

  ## Categories

  - **Arithmetic**: Add, Sub, Mul, Neg, Div, Mod
  - **Bitwise**: BitAnd, BitOr, BitNot, BitXor, Shl, Shr
  - **Reduction**: ReduceAnd, ReduceOr, ReduceXor
  - **Compare**: Eq, Neq, Lt, Gt, Lte, Gte
  - **Memory**: Mem, MemRead, MemWrite
  - **Structure**: Reg, Mux, Assign, Cast, Slice, Concat, Replicate
  - **IO**: Blackbox, Tristate
  """

  alias Hw.IR.Types.{Signal, Const}

  @type value :: Signal.t() | Const.t() | struct()
  @type op :: struct()

  # Make aliases available to users of this module
  defmacro __using__(_opts) do
    quote do
      alias Hw.IR.Ops.{
        # Arithmetic
        Add, Sub, Mul, Neg, Div, Mod,
        # Bitwise
        BitAnd, BitOr, BitNot, BitXor, Shl, Shr, Shra,
        # Reduction
        ReduceAnd, ReduceOr, ReduceXor, Replicate,
        # Compare
        Eq, Neq, Lt, Gt, Lte, Gte,
        # Memory
        Mem, MemRead, MemWrite,
        # Structure
        Reg, Mux, Assign, Cast, Slice, Concat,
        # IO
        Blackbox, Tristate
      }
    end
  end
end
