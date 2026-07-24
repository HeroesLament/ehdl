defmodule Hw.Emit.Verilog.Ops do
  @moduledoc """
  Verilog emission for combinational operations.

  Delegates to submodules by category:
  - `Arithmetic` - add, sub, mul, neg, div, mod, abs, min, max, mul_round, clog2
  - `Bitwise` - and, or, not, xor, shifts, reductions, popcount
  - `Compare` - eq, neq, lt, gt, lte, gte
  - `Bits` - slice, concat, replicate, cast
  - `Memory` - memory reads
  - `Structure` - mux, assign
  - `Complex` - complex number operations
  - `Value` - value emission helpers
  """

  alias Hw.IR.Ops.{Add, Sub, Mul, Neg, Div, Mod, Abs, Min, Max, MulRound, Clog2,
                   BitAnd, BitOr, BitNot, BitXor, Shl, Shr, Shra,
                   ReduceAnd, ReduceOr, ReduceXor, Popcount,
                   SignExtend, ZeroExtend, ReverseBits,
                   Eq, Neq, Lt, Gt, Lte, Gte,
                   Slice, Concat, Replicate, Cast,
                   MemRead, Mux, Assign,
                   ComplexMul, ComplexAdd, ComplexSub, ComplexMagSq, ComplexConj}

  alias Hw.Emit.Verilog.Ops.{Arithmetic, Bitwise, Compare, Bits, Memory, Structure, Complex}

  # Re-export emit_value for use by other modules
  defdelegate emit_value(val), to: Hw.Emit.Verilog.Ops.Value
  defdelegate get_width(val), to: Hw.Emit.Verilog.Ops.Value

  @doc "Emit a single combinational operation as Verilog."

  # Arithmetic
  def emit_comb_op(%Add{} = op), do: Arithmetic.emit(op)
  def emit_comb_op(%Sub{} = op), do: Arithmetic.emit(op)
  def emit_comb_op(%Mul{} = op), do: Arithmetic.emit(op)
  def emit_comb_op(%Neg{} = op), do: Arithmetic.emit(op)
  def emit_comb_op(%Div{} = op), do: Arithmetic.emit(op)
  def emit_comb_op(%Mod{} = op), do: Arithmetic.emit(op)
  def emit_comb_op(%Abs{} = op), do: Arithmetic.emit(op)
  def emit_comb_op(%Min{} = op), do: Arithmetic.emit(op)
  def emit_comb_op(%Max{} = op), do: Arithmetic.emit(op)
  def emit_comb_op(%MulRound{} = op), do: Arithmetic.emit(op)
  def emit_comb_op(%Clog2{} = op), do: Arithmetic.emit(op)

  # Bitwise
  def emit_comb_op(%BitAnd{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%BitOr{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%BitNot{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%BitXor{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%Shl{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%Shr{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%Shra{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%ReduceAnd{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%ReduceOr{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%ReduceXor{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%Popcount{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%SignExtend{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%ZeroExtend{} = op), do: Bitwise.emit(op)
  def emit_comb_op(%ReverseBits{} = op), do: Bitwise.emit(op)

  # Compare
  def emit_comb_op(%Eq{} = op), do: Compare.emit(op)
  def emit_comb_op(%Neq{} = op), do: Compare.emit(op)
  def emit_comb_op(%Lt{} = op), do: Compare.emit(op)
  def emit_comb_op(%Gt{} = op), do: Compare.emit(op)
  def emit_comb_op(%Lte{} = op), do: Compare.emit(op)
  def emit_comb_op(%Gte{} = op), do: Compare.emit(op)

  # Bits
  def emit_comb_op(%Slice{} = op), do: Bits.emit(op)
  def emit_comb_op(%Concat{} = op), do: Bits.emit(op)
  def emit_comb_op(%Replicate{} = op), do: Bits.emit(op)
  def emit_comb_op(%Cast{} = op), do: Bits.emit(op)

  # Memory
  def emit_comb_op(%MemRead{} = op), do: Memory.emit(op)

  # Structure
  def emit_comb_op(%Mux{} = op), do: Structure.emit(op)
  def emit_comb_op(%Assign{} = op), do: Structure.emit(op)

  # Complex
  def emit_comb_op(%ComplexMul{} = op), do: Complex.emit(op)
  def emit_comb_op(%ComplexAdd{} = op), do: Complex.emit(op)
  def emit_comb_op(%ComplexSub{} = op), do: Complex.emit(op)
  def emit_comb_op(%ComplexMagSq{} = op), do: Complex.emit(op)
  def emit_comb_op(%ComplexConj{} = op), do: Complex.emit(op)

  @doc """
  casez-aware combinational emit. Only `Mux` behaves differently under casez
  (it may render a `casez` instead of a priority if-chain); every other op
  ignores the flag and falls through to the arity-1 form.
  """
  def emit_comb_op(%Mux{} = op, casez?), do: Structure.emit(op, casez?)
  def emit_comb_op(op, _casez?), do: emit_comb_op(op)
end
