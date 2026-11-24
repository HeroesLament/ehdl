defmodule Hw.ECP5.OBZPU do
  @moduledoc """
  ECP5 `OBZPU`. Tristate output pad buffer with the pull-up on.

  **Builds through oxibit-ecp5 (written as the canonical buffer plus its PULLMODE); not on hardware.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :i, 1
  input :t, 1
  output :o, 1

  blackbox :obzpu, "OBZPU",
    ports: [
      I: :i,
      T: :t,
      O: :o
    ]
end
