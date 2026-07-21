# Bitwise operations: And, Or, Not, Xor, Shl, Shr, Reductions, Replicate

defmodule Hw.IR.Ops.BitAnd do
  @moduledoc "Bitwise AND"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.BitOr do
  @moduledoc "Bitwise OR"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.BitNot do
  @moduledoc "Bitwise NOT (invert)"
  @enforce_keys [:output, :input]
  defstruct [:output, :input]
end

defmodule Hw.IR.Ops.BitXor do
  @moduledoc "Bitwise XOR"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Shl do
  @moduledoc "Shift left (logical)"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Shr do
  @moduledoc "Shift right (logical or arithmetic based on signedness)"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Shra do
  @moduledoc "Arithmetic shift right (sign-extending)"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

# Reduction operations (output is always 1-bit)

defmodule Hw.IR.Ops.ReduceAnd do
  @moduledoc "Reduction AND: &a (1 if all bits are 1)"
  @enforce_keys [:output, :input]
  defstruct [:output, :input]
end

defmodule Hw.IR.Ops.ReduceOr do
  @moduledoc "Reduction OR: |a (1 if any bit is 1)"
  @enforce_keys [:output, :input]
  defstruct [:output, :input]
end

defmodule Hw.IR.Ops.ReduceXor do
  @moduledoc "Reduction XOR: ^a (1 if odd number of 1s)"
  @enforce_keys [:output, :input]
  defstruct [:output, :input]
end

defmodule Hw.IR.Ops.Replicate do
  @moduledoc "Bit replication: {N{a}} - replicate input N times"
  @enforce_keys [:output, :input, :count]
  defstruct [:output, :input, :count]
end

defmodule Hw.IR.Ops.Popcount do
  @moduledoc """
  Population count: count number of 1 bits in input.

  Output width is clog2(input_width + 1).
  E.g., 8-bit input -> 4-bit output (can represent 0-8).
  """
  @enforce_keys [:output, :input]
  defstruct [:output, :input]
end

defmodule Hw.IR.Ops.SignExtend do
  @moduledoc """
  Sign extension: widen a signed value by replicating the sign bit.

  E.g., 8-bit signed -> 16-bit signed.
  """
  @enforce_keys [:output, :input, :width]
  defstruct [:output, :input, :width]
end

defmodule Hw.IR.Ops.ZeroExtend do
  @moduledoc """
  Zero extension: widen an unsigned value by padding with zeros.

  E.g., 8-bit -> 16-bit with upper bits = 0.
  """
  @enforce_keys [:output, :input, :width]
  defstruct [:output, :input, :width]
end

defmodule Hw.IR.Ops.ReverseBits do
  @moduledoc """
  Bit reversal: reverse the bit order of input.

  E.g., 8'b10110001 -> 8'b10001101
  """
  @enforce_keys [:output, :input]
  defstruct [:output, :input]
end
