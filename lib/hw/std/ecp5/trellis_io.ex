defmodule Hw.ECP5.TRELLIS_IO do
  @moduledoc """
  ECP5 `TRELLIS_IO`. Generic pad: DIR parameter INPUT, OUTPUT or BIDIR.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/pad_probe.v`, JTAG oracle), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :DIR, default: "INPUT"

  input :i, 1
  input :t, 1
  output :o, 1
  inout :b, 1

  blackbox :trellis_io, "TRELLIS_IO",
    params: [
      DIR: :DIR
    ],
    ports: [
      I: :i,
      T: :t,
      O: :o,
      B: :b
    ]
end
