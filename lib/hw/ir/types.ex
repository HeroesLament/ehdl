defmodule Hw.IR.Types do
  @moduledoc """
  Fundamental types for hardware IR.

  These are the "nouns" of the system — they describe what exists,
  not what happens. All fields are explicit. No inference.

  This module is a convenience index. Each type lives in its own file
  under `lib/hw/ir/types/`:

    - `Hw.IR.Types.Signal`     — named wire or storage location
    - `Hw.IR.Types.Clock`      — clock domain
    - `Hw.IR.Types.Const`      — constant value with explicit width
    - `Hw.IR.Types.Param`      — overridable module parameter
    - `Hw.IR.Types.ParamRef`   — reference to a parameter in an expression
    - `Hw.IR.Types.Localparam` — fixed compile-time constant

  ## Source Locations

  Every struct that originates from a macro declaration carries an optional
  `source_location` field of type `Hw.Analysis.Location.t()`. This is
  populated at macro expansion time via `__ENV__` and used by `Hw.Analysis`
  and the LSP server for diagnostics and go-to-definition.

  Existing code that does not populate `source_location` continues to work —
  it simply produces diagnostics without file/line information.
  """
end
