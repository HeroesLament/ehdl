defmodule Hw.ECP5.ODDRX2DQA do
  @moduledoc """
  ECP5 `ODDRX2DQA`. DDR memory DQ output gearbox, written on the DQS group's DQSW270.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/dqs_probe.v`: strobe and DQ drive, DATAVALID / BURSTDET, DQ loopback), not through this wrapper. The DDR tristates reach the pad only with the PIO TRIMUX_TSREG on IOLTO, which oxibit sets (nextpnr does not). Bring-up as LiteDRAM ECP5DDRPHYInit: DLL lock, freeze, stop ECLK, reset, release, pause, DLL update, release pause.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :GSR, default: "DISABLED"

  input :d3, 1
  input :d2, 1
  input :d1, 1
  input :d0, 1
  input :dqsw270, 1
  input :sclk, 1
  input :eclk, 1
  input :rst, 1
  output :q, 1

  blackbox :oddrx2dqa, "ODDRX2DQA",
    params: [
      GSR: :GSR
    ],
    ports: [
      D3: :d3,
      D2: :d2,
      D1: :d1,
      D0: :d0,
      DQSW270: :dqsw270,
      SCLK: :sclk,
      ECLK: :eclk,
      RST: :rst,
      Q: :q
    ]
end
