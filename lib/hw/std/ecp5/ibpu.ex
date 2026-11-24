defmodule Hw.ECP5.IBPU do
  @moduledoc """
  ECP5 `IBPU`. Input pad buffer with the pull-up on.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/pad_probe.v`, JTAG oracle), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :i, 1
  output :o, 1

  blackbox :ibpu, "IBPU",
    ports: [
      I: :i,
      O: :o
    ]
end
