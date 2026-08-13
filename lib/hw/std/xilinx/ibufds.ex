defmodule Hw.Xilinx.IBUFDS do
  @moduledoc """
  Xilinx 7-series differential input buffer.

  Converts an LVDS pair on the package into a single-ended fabric signal. Both
  halves of the pair are real top-level ports and both need a `PACKAGE_PIN`
  constraint; nextpnr-xilinx places them independently rather than inferring
  the N pin from the P pin the way Vivado does.

  `DIFF_TERM` switches in the on-die 100 ohm differential termination. For a
  source-synchronous receive bus with no external termination resistors — which
  is how the LibreSDR wires the AD9363 — it must be TRUE, or the pair is
  unterminated and reflections eat the eye.
  """

  use Hw.Component

  input  :i,  1
  input  :ib, 1
  output :o,  1

  blackbox :ibufds, "IBUFDS",
    params: [
      DIFF_TERM: "TRUE",
      IBUF_LOW_PWR: "TRUE",
      IOSTANDARD: "LVDS_25"
    ],
    ports: [
      I: :i,
      IB: :ib,
      O: :o
    ]
end
