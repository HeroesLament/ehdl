defmodule Hw.ECP5.IBPD do
  @moduledoc """
  ECP5 `IBPD`. Input pad buffer with the pull-down on.

  **Builds through oxibit-ecp5 (written as the canonical buffer plus its PULLMODE); not on hardware.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :i, 1
  output :o, 1

  blackbox :ibpd, "IBPD",
    ports: [
      I: :i,
      O: :o
    ]
end
