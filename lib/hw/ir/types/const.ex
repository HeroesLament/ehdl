defmodule Hw.IR.Types.Const do
  @moduledoc """
  A constant value with explicit width and signedness.

  No implicit sizing. If you want a 16-bit zero, you say so.
  """

  @type t :: %__MODULE__{
    value:  integer(),
    width:  pos_integer(),
    signed: :signed | :unsigned
  }

  @enforce_keys [:value, :width, :signed]
  defstruct [:value, :width, :signed]

  @spec new(integer(), pos_integer(), :signed | :unsigned) :: t()
  def new(value, width, signed \\ :unsigned) do
    %__MODULE__{value: value, width: width, signed: signed}
  end
end
