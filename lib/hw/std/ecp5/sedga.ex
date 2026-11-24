defmodule Hw.ECP5.SEDGA do
  @moduledoc """
  ECP5 `SEDGA`. Soft-error detection: CRC check of the configuration SRAM on the internal oscillator.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/clk_probe.v`), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :SED_CLK_FREQ, default: "2.4"
  param :CHECKALWAYS, default: "DISABLED"

  input :sedenable, 1
  input :sedstart, 1
  input :sedfrcerr, 1
  output :seddone, 1
  output :sedinprog, 1
  output :sederr, 1

  blackbox :sedga, "SEDGA",
    params: [
      SED_CLK_FREQ: :SED_CLK_FREQ,
      CHECKALWAYS: :CHECKALWAYS
    ],
    ports: [
      SEDENABLE: :sedenable,
      SEDSTART: :sedstart,
      SEDFRCERR: :sedfrcerr,
      SEDDONE: :seddone,
      SEDINPROG: :sedinprog,
      SEDERR: :sederr
    ]
end
