defmodule Hw.ECP5.BBPU do
  @moduledoc """
  ECP5 `BBPU`. Bidirectional pad buffer with the pull-up on.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/pad_probe.v`, JTAG oracle), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :i, 1
  input :t, 1
  output :o, 1
  inout :b, 1

  blackbox :bbpu, "BBPU",
    ports: [
      I: :i,
      T: :t,
      O: :o,
      B: :b
    ]
end
