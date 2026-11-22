defmodule Hw.Xilinx.OBUFT do
  @moduledoc """
  Xilinx 7-series tristate output buffer: `i` drives the pad, `t` high
  releases it (Z). No read-back; `Hw.Xilinx.IOBUF` is the bidirectional one.
  """

  use Hw.Component

  input  :i, 1
  input  :t, 1
  output :o, 1

  blackbox :obuft, "OBUFT",
    ports: [
      I: :i,
      T: :t,
      O: :o
    ]
end
