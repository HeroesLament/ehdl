# Structural operations: Reg, Mux, Assign, Cast, Slice, Concat

defmodule Hw.IR.Ops.Reg do
  @moduledoc """
  A clocked register (flip-flop or vector of flip-flops).

  This is where time enters the model. Everything else is combinational.
  Reset and enable are explicit - no inference.

  async_reset: atom() | nil - name of async reset signal (nil = sync reset only)
  """

  @enforce_keys [:output, :input, :clock]
  defstruct [:output, :input, :clock, :reset_value, :enable, :async_reset]
end

defmodule Hw.IR.Ops.Mux do
  @moduledoc """
  Priority multiplexer.

  Cases are evaluated in order. First match wins.
  Each case is {condition, value}. Default is required.

  This is the lowered form of if/case - no syntax sugar here.
  """

  @enforce_keys [:output, :cases, :default]
  defstruct [:output, :cases, :default]
end

defmodule Hw.IR.Ops.Assign do
  @moduledoc """
  Combinational assignment (continuous).

  This is a direct wire connection, not storage.
  No clock, no state - just "output = input".
  """

  @enforce_keys [:output, :input]
  defstruct [:output, :input]
end

defmodule Hw.IR.Ops.Cast do
  @moduledoc """
  Explicit type conversion.

  No implicit truncation or extension. Ever.
  If you want to change width or signedness, you say so explicitly.

  kind: :truncate | :zero_extend | :sign_extend | :reinterpret
  """

  @enforce_keys [:output, :input, :kind]
  defstruct [:output, :input, :kind]
end

defmodule Hw.IR.Ops.Slice do
  @moduledoc "Bit slice extraction: sig[hi:lo]"
  @enforce_keys [:output, :input, :hi, :lo]
  defstruct [:output, :input, :hi, :lo]
end

defmodule Hw.IR.Ops.Concat do
  @moduledoc "Concatenation of signals: {a, b, c}"
  @enforce_keys [:output, :inputs]
  defstruct [:output, :inputs]
end
