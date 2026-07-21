# IO operations: Blackbox (vendor primitives), Tristate (bidirectional)

defmodule Hw.IR.Ops.Blackbox do
  @moduledoc """
  Vendor primitive or external module instantiation.

  For PLLs, SERDES, or any module we don't elaborate.
  Parameters and ports are passed through verbatim.
  """

  @enforce_keys [:name, :module, :ports]
  defstruct [:name, :module, :params, :ports, attrs: []]
end

defmodule Hw.IR.Ops.Tristate do
  @moduledoc """
  Tri-state buffer for bidirectional IO.

  When enable is high, drives output_value to io.
  When enable is low, io is high-impedance (Z) and input_value reads io.
  """

  @enforce_keys [:io, :output_value, :output_enable, :input_value]
  defstruct [:io, :output_value, :output_enable, :input_value]
end
