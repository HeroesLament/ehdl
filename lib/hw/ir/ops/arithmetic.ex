# Arithmetic operations: Add, Sub, Mul, Neg, Div, Mod

defmodule Hw.IR.Ops.Add do
  @moduledoc """
  Signed or unsigned addition.

  Both operands must have the same signedness.
  Width of result must be explicit (no automatic growth).
  """

  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Sub do
  @moduledoc """
  Signed or unsigned subtraction.

  Same rules as Add - explicit signedness, explicit width.
  """

  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Mul do
  @moduledoc """
  Signed or unsigned multiplication.

  Result width should be sum of input widths to avoid overflow,
  but we allow explicit truncation via output signal width.
  """

  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Neg do
  @moduledoc """
  Two's complement negation (unary minus).

  Output width matches input width.
  """

  @enforce_keys [:output, :input]
  defstruct [:output, :input]
end

defmodule Hw.IR.Ops.Div do
  @moduledoc """
  Integer division.

  Note: Division is expensive in hardware. Consider if you really need it.
  """

  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Mod do
  @moduledoc """
  Integer modulo (remainder).

  Note: Modulo is expensive in hardware. Consider if you really need it.
  """

  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Abs do
  @moduledoc """
  Absolute value of signed input.

  Output width matches input width.
  For MIN_INT, result wraps (standard two's complement behavior).
  """

  @enforce_keys [:output, :input]
  defstruct [:output, :input]
end

defmodule Hw.IR.Ops.Min do
  @moduledoc """
  Minimum of two values.

  If either input is signed, uses signed comparison.
  Output width is max of input widths.
  """

  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Max do
  @moduledoc """
  Maximum of two values.

  If either input is signed, uses signed comparison.
  Output width is max of input widths.
  """

  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.MulRound do
  @moduledoc """
  Multiply with rounding and shift.

  Computes: (a * b + (1 << (shift - 1))) >>> shift

  Common DSP operation for fixed-point multiplication with proper rounding.
  """

  @enforce_keys [:output, :a, :b, :shift]
  defstruct [:output, :a, :b, :shift]
end

defmodule Hw.IR.Ops.Clog2 do
  @moduledoc """
  Ceiling of log base 2.

  Computes the number of bits needed to represent values 0 to (input-1).
  Emits as $clog2() in Verilog.

  Primarily used for computing address widths from depth parameters.
  """

  @enforce_keys [:output, :input]
  defstruct [:output, :input]
end
