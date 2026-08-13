defmodule Hw.Xilinx.OBUF do
  @moduledoc """
  Xilinx 7-series single-ended output buffer.

  Instantiated explicitly rather than left to yosys's `iopadmap`, so that a
  design mixing hand-instantiated differential buffers with inferred
  single-ended ones does not depend on pass ordering to come out right.
  """

  use Hw.Component

  input  :i, 1
  output :o, 1

  blackbox :obuf, "OBUF",
    ports: [
      I: :i,
      O: :o
    ]
end
