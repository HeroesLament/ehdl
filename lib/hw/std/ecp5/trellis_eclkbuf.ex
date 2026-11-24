defmodule Hw.ECP5.TRELLIS_ECLKBUF do
  @moduledoc """
  ECP5 `TRELLIS_ECLKBUF`. Edge-clock buffer from fabric onto a bank edge clock.

  **Builds through oxibit-ecp5; not on hardware.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :eclki, 1
  output :eclko, 1

  blackbox :trellis_eclkbuf, "TRELLIS_ECLKBUF",
    ports: [
      ECLKI: :eclki,
      ECLKO: :eclko
    ]
end
