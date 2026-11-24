defmodule Hw.ECP5.TSHX2DQSA do
  @moduledoc """
  ECP5 `TSHX2DQSA`. DDR memory DQS tristate gearbox (DQSW).

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/dqs_probe.v`: strobe and DQ drive, DATAVALID / BURSTDET, DQ loopback), not through this wrapper. The DDR tristates reach the pad only with the PIO TRIMUX_TSREG on IOLTO, which oxibit sets (nextpnr does not). Bring-up as LiteDRAM ECP5DDRPHYInit: DLL lock, freeze, stop ECLK, reset, release, pause, DLL update, release pause.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :GSR, default: "DISABLED"
  param :REGSET, default: "SET"

  input :t1, 1
  input :t0, 1
  input :sclk, 1
  input :eclk, 1
  input :dqsw, 1
  input :rst, 1
  output :q, 1

  blackbox :tshx2dqsa, "TSHX2DQSA",
    params: [
      GSR: :GSR,
      REGSET: :REGSET
    ],
    ports: [
      T1: :t1,
      T0: :t0,
      SCLK: :sclk,
      ECLK: :eclk,
      DQSW: :dqsw,
      RST: :rst,
      Q: :q
    ]
end
