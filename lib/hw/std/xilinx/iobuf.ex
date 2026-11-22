defmodule Hw.Xilinx.IOBUF do
  @moduledoc """
  Xilinx 7-series bidirectional pad buffer: `i` drives the pad, `t` high
  releases it (Z), `o` reads it back, `io` is the pad (an `inout` of the top).

  The Xilinx counterpart of `Hw.ECP5.BB`. A `tristate` statement lowers to the
  ECP5 `BB` today regardless of target, so an xc7 design that needs a
  bidirectional pin instantiates this explicitly instead.

      instance :sda_pad, Hw.Xilinx.IOBUF, i: :sda_out, t: :sda_release, o: :sda_in, io: :sda
  """

  use Hw.Component

  input  :i, 1
  input  :t, 1
  output :o, 1
  inout  :io, 1

  blackbox :iobuf, "IOBUF",
    ports: [
      I: :i,
      T: :t,
      O: :o,
      IO: :io
    ]
end
