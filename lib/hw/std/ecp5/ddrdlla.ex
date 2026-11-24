defmodule Hw.ECP5.DDRDLLA do
  @moduledoc """
  ECP5 `DDRDLLA`. Master DDR DLL: measures the ECLK period and hands the delay code (DDRDEL) to the DQSBUFMs of its corner.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/dqs_probe.v`: strobe and DQ drive, DATAVALID / BURSTDET, DQ loopback), not through this wrapper. The DDR tristates reach the pad only with the PIO TRIMUX_TSREG on IOLTO, which oxibit sets (nextpnr does not). Bring-up as LiteDRAM ECP5DDRPHYInit: DLL lock, freeze, stop ECLK, reset, release, pause, DLL update, release pause.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :FORCE_MAX_DELAY, default: "NO"
  param :GSR, default: "DISABLED"

  input :clk, 1
  input :rst, 1
  input :uddcntln, 1
  input :freeze, 1
  output :ddrdel, 1
  output :lock, 1
  output :dcntl7, 1
  output :dcntl6, 1
  output :dcntl5, 1
  output :dcntl4, 1
  output :dcntl3, 1
  output :dcntl2, 1
  output :dcntl1, 1
  output :dcntl0, 1

  blackbox :ddrdlla, "DDRDLLA",
    params: [
      FORCE_MAX_DELAY: :FORCE_MAX_DELAY,
      GSR: :GSR
    ],
    ports: [
      CLK: :clk,
      RST: :rst,
      UDDCNTLN: :uddcntln,
      FREEZE: :freeze,
      DDRDEL: :ddrdel,
      LOCK: :lock,
      DCNTL7: :dcntl7,
      DCNTL6: :dcntl6,
      DCNTL5: :dcntl5,
      DCNTL4: :dcntl4,
      DCNTL3: :dcntl3,
      DCNTL2: :dcntl2,
      DCNTL1: :dcntl1,
      DCNTL0: :dcntl0
    ]
end
