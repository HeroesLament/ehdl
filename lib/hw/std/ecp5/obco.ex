defmodule Hw.ECP5.OBCO do
  @moduledoc """
  ECP5 `OBCO`. Complementary output pair (OT true, OC complement) on a differential pad pair.

  **Builds through oxibit-ecp5 (written as the canonical buffer plus its PULLMODE); not on hardware.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :i, 1
  output :ot, 1
  output :oc, 1

  blackbox :obco, "OBCO",
    ports: [
      I: :i,
      OT: :ot,
      OC: :oc
    ]
end
