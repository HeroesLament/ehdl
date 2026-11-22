defmodule Hw.ECP5.IDDRX1F do
  @moduledoc """
  ECP5 input DDR register (X1 gearing), in the IOLOGIC beside the pad.

  Captures `d` on both edges of `sclk`: `q0` holds the rising-edge sample and
  `q1` the falling-edge one, both presented on the rising edge (one SCLK of
  latency). `d` must come straight from a pad (or a `Hw.ECP5.DELAYF` /
  `DELAYG` on it), not from fabric. `rst` is synchronous to `sclk`.

  The ECP5 counterpart of `Hw.Xilinx.IDDR`; RGMII receive and source-
  synchronous ADC buses are the use.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :GSR, default: "ENABLED"

  input :d, 1
  input :sclk, 1
  input :rst, 1
  output :q0, 1
  output :q1, 1

  blackbox :iddr, "IDDRX1F",
    params: [GSR: :GSR],
    ports: [
      D: :d,
      SCLK: :sclk,
      RST: :rst,
      Q0: :q0,
      Q1: :q1
    ]
end
