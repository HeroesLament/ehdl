defmodule Hw.Xilinx.IDELAYCTRL do
  @moduledoc """
  The calibration block every `IDELAYE2` in an I/O bank depends on.

  `IDELAYE2` is not self-contained. UG471 requires an `IDELAYCTRL` fed by a
  200 MHz reference in the same bank; it continuously trims the delay chain
  against that reference, and `RDY` gates the delay line. Without one, the taps
  do not approximate a delay -- they produce nothing.

  That is not a reading of the datasheet, it is a measurement. Seven IDELAYE2
  were built into the receive path with no IDELAYCTRL, at eight different tap
  values, and every one of the 1024 captured words on every tap read exactly
  zero while the undelayed DATA_CLK lane ran at 16.16 MHz. See HANDOFF.md.

  ## The reference clock

  Not a PL CMT. Every `PLLE2_BASE` and `MMCME2_BASE` tried under openXC7 failed
  to lock -- two primitives, two site types, two clock routes, nine multipliers,
  ~15 bitstreams, zero locks. The reference here is the PS's `FCLK1`, which the
  FSBL already configures at exactly 200 MHz (IO PLL 999.9 MHz / 5) and which
  measured 199.97 MHz in the fabric.

  ## RST

  UG471 wants `RST` asserted for at least 60 ns after configuration before
  `RDY` is meaningful. End-of-configuration GSR may well do that for us, so
  this design routes `RST` to a software-controlled register bit instead of
  guessing: tie-low and explicit-pulse can then both be tested without a
  rebuild, and whichever is actually required becomes a measurement rather than
  an assumption.

  ## What nextpnr does with this

  `pack_io_xc7.cc` has real IDELAYCTRL support -- it resolves `IODELAY_GROUP`,
  and DUPLICATES the cell into every bank that contains a group member, which
  is why one instance here covers all seven lanes. It also hard-errors with
  "Found IDELAYCTRL but no I/ODELAYs in group", so this cannot be built or
  tested on its own; it only exists alongside the delays it serves.
  """

  use Hw.Component

  input  :refclk, 1
  input  :rst,    1
  output :rdy,    1

  blackbox :idelayctrl, "IDELAYCTRL",
    attrs: [keep: "true"],
    ports: [
      REFCLK: :refclk,
      RST: :rst,
      RDY: :rdy
    ]
end
