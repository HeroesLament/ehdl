defmodule Hw.Xilinx.IBUF do
  @moduledoc """
  Xilinx 7-series single-ended input buffer. The input counterpart of
  `Hw.Xilinx.OBUF`, instantiated explicitly for the same reason: a design that
  mixes hand-instantiated buffers with `iopadmap`-inferred ones should not
  depend on pass ordering.
  """

  use Hw.Component

  input  :i, 1
  output :o, 1

  blackbox :ibuf, "IBUF",
    ports: [
      I: :i,
      O: :o
    ]
end
