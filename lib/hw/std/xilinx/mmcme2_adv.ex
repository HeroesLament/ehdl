defmodule Hw.Xilinx.MMCME2_ADV do
  @moduledoc """
  Xilinx 7-series MMCM with its dynamic reconfiguration port (DRP) exposed.

  `Hw.Xilinx.MMCME2_BASE` fixes the output frequencies at build time. This
  variant lets the fabric rewrite the MMCM's configuration registers at run
  time, which is what a frequency sweep needs: one bitstream, many clocks.

  The DRP is a 7-bit-address, 16-bit-data register port clocked by `dclk`.
  A transaction is one `den` pulse (with `dwe` high for a write); `drdy`
  pulses when it completes and `dout` is valid with it on a read. The register
  map is XAPP888's, and the fabfarm `cmt_drp` campaign confirmed it on this
  part from the fabric side (1,408 of 1,422 features). The usual reprogram
  sequence: assert `rst`, read-modify-write the counter registers, release
  `rst`, wait for `locked`.

  Only `clkout0` and `clkout1` are brought out. Every output is another
  global clock net and this toolchain's clock router is the binding
  constraint (see `MMCME2_BASE`); add outputs when a design needs them.

  ## Fixed choices

  - Feedback is internal (`CLKFBOUT` -> `CLKFBIN` inside this module), for
    the same reason as `MMCME2_BASE`: an open feedback path never locks.
  - `CLKIN1` only; `CLKINSEL` is tied to 1 and `CLKIN2` to 0.
  - Dynamic phase shift (`PS*`) is tied off.

  ## Frequencies

      f_vco = f_in / DIVCLK_DIVIDE * CLKFBOUT_MULT_F    (600..1200 MHz, -1)
      f_out = f_vco / CLKOUTn_DIVIDE

  Pass `CLKFBOUT_MULT_F`: this nextpnr fork derives the loop filter and lock
  tables from it. A DRP rewrite of the multiplier must rewrite those tables
  too (XAPP888 0x18..0x1A, 0x4E, 0x4F); a rewrite of an output divider alone
  does not.

  **Never validated on hardware** as an EHDL instance.
  """

  use Hw.Component

  param :BANDWIDTH, default: "OPTIMIZED"
  param :CLKIN1_PERIOD, default: 10.0
  param :DIVCLK_DIVIDE, default: 1
  param :CLKFBOUT_MULT_F, default: 10.0
  param :CLKOUT0_DIVIDE_F, default: 10.0
  param :CLKOUT1_DIVIDE, default: 10
  param :STARTUP_WAIT, default: "FALSE"

  input :clkin1, 1
  input :rst, 1
  input :pwrdwn, 1

  input :dclk, 1
  input :den, 1
  input :dwe, 1
  input :daddr, 7
  input :din, 16
  output :dout, 16
  output :drdy, 1

  output :clkout0, 1
  output :clkout1, 1
  output :locked, 1

  # Internal feedback. Not a port: see the moduledoc.
  wire :clkfb, 1

  blackbox :mmcm, "MMCME2_ADV",
    params: [
      BANDWIDTH: :BANDWIDTH,
      COMPENSATION: "INTERNAL",
      CLKIN1_PERIOD: :CLKIN1_PERIOD,
      DIVCLK_DIVIDE: :DIVCLK_DIVIDE,
      CLKFBOUT_MULT_F: :CLKFBOUT_MULT_F,
      CLKFBOUT_PHASE: 0.0,
      CLKOUT0_DIVIDE_F: :CLKOUT0_DIVIDE_F,
      CLKOUT0_PHASE: 0.0,
      CLKOUT0_DUTY_CYCLE: 0.5,
      CLKOUT1_DIVIDE: :CLKOUT1_DIVIDE,
      CLKOUT1_PHASE: 0.0,
      CLKOUT1_DUTY_CYCLE: 0.5,
      STARTUP_WAIT: :STARTUP_WAIT
    ],
    ports: [
      CLKIN1: :clkin1,
      CLKIN2: 0,
      CLKINSEL: 1,
      CLKFBIN: :clkfb,
      CLKFBOUT: :clkfb,
      RST: :rst,
      PWRDWN: :pwrdwn,
      DCLK: :dclk,
      DEN: :den,
      DWE: :dwe,
      DADDR: :daddr,
      DI: :din,
      DO: :dout,
      DRDY: :drdy,
      PSCLK: 0,
      PSEN: 0,
      PSINCDEC: 0,
      CLKOUT0: :clkout0,
      CLKOUT1: :clkout1,
      LOCKED: :locked
    ]
end
