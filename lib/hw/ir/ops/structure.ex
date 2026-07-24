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

  ## Optional casez metadata (`selector` + `patterns`)

  A Mux lowered from an `hdl_case` on a single subject additionally carries the
  structure needed to emit a parallel Verilog `casez` instead of the priority
  `if`-chain that `cases` lowers to:

    * `selector` — the `%Signal{}` the case switches on (the subject).
    * `patterns` — one entry PER `cases` entry, aligned by position, each a
      `{value, care_mask, width}` tuple. `care_mask` bit set = that bit is a
      literal to match (its value in `value`); clear = don't-care (`?` in casez,
      from a `_`/capture segment).

  Both are `nil` for muxes that did not come from a single-subject case (plain
  `if`/`else`, or a case whose arms are not static subject patterns). The
  emitter uses them ONLY under `opts[:casez]`; with casez off it ignores them and
  emits the priority `if`-chain exactly as before, so the metadata is inert by
  default. The `cases` conditions remain valid either way — casez emission just
  presents the same first-match semantics in a form yosys can decode once and
  parallelize (a priority `if`-chain is ~2.5x the LUTs of the equivalent case).
  """

  @enforce_keys [:output, :cases, :default]
  defstruct [:output, :cases, :default, :selector, :patterns]
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
