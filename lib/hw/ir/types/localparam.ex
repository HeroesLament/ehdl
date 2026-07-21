defmodule Hw.IR.Types.Localparam do
  @moduledoc """
  A localparam constant (e.g. FSM state encoding).

  Unlike `Hw.IR.Types.Param` (which can be overridden at instantiation),
  localparams are fixed at definition time. Used for FSM state values,
  lookup table indices, etc.

  The `source_location` field is populated by macros at expansion time
  and used by `Hw.Analysis` for diagnostics.
  """

  alias Hw.Analysis.Location

  @type t :: %__MODULE__{
    name:            atom(),
    value:           integer(),
    width:           pos_integer(),
    source_location: Location.t() | nil
  }

  @enforce_keys [:name, :value, :width]
  defstruct [:name, :value, :width, source_location: nil]
end
