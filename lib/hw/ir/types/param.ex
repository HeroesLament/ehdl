# Parameter types for parameterized modules

defmodule Hw.IR.Types.Param do
  @moduledoc """
  A module parameter declaration.

  Parameters are compile-time constants that can be overridden
  when instantiating a module.

  The `constraint` field optionally validates the value at analysis time.
  The `source_location` field is populated by the `param` macro at
  expansion time and used by `Hw.Analysis` for diagnostics.
  """

  alias Hw.Analysis.Location

  @type constraint ::
    :pos_integer
    | :non_neg_integer
    | :integer
    | :boolean
    | {:range, integer(), integer()}
    | {:one_of, [term()]}

  @type t :: %__MODULE__{
    name:            atom(),
    default:         integer() | nil,
    value:           integer() | nil,
    constraint:      constraint() | nil,
    source_location: Location.t() | nil
  }

  @enforce_keys [:name]
  defstruct [:name, :default, :value, :constraint, source_location: nil]
end

defmodule Hw.IR.Types.ParamRef do
  @moduledoc """
  A reference to a parameter in an expression.

  Used where a width or value depends on a parameter.
  Example: `output :data, WIDTH` creates a signal with width = ParamRef(:WIDTH)
  """

  @type t :: %__MODULE__{
    name: atom()
  }

  @enforce_keys [:name]
  defstruct [:name]
end
