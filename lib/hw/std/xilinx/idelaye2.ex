defmodule Hw.Xilinx.IDELAYE2 do
  @moduledoc """
  Xilinx 7-series input delay element -- 31 taps on a single-ended fabric net.

  Sits between an `IBUFDS` and whatever captures the lane, and shifts that lane
  in time relative to the capture clock. That is the only instrument this design
  has for measuring receive margin: sweep the tap, decode at each setting, and
  the range of taps that still decode IS the eye.

  ## What openXC7 can and cannot do with this

  Measured, not assumed (see `ehdl/designs/iserdes_probe/`): every FASM feature
  nextpnr-xilinx emits for `IDELAYE2` resolves in prjxray's `segbits_rioi3.db`
  -- `IDELAY_VALUE[4:0]` in both polarities, all three `IDELAY_TYPE`s,
  `DELAY_SRC`, `PIPE_SEL`, `HIGH_PERFORMANCE_MODE`, both input inversions.
  21 of 21. The primitive is fully characterised.

  `IDELAY_TYPE` is FIXED here, so the tap is a bitstream constant and a sweep
  costs one bitstream per tap. VARIABLE and VAR_LOAD are documented and would
  make the tap runtime-settable, but both need an `IDELAYCTRL` fed by a
  calibrated 200 MHz reference, which needs an MMCM -- three more primitives to
  prove out. Not yet.

  ## No IDELAYCTRL

  Xilinx requires `IDELAYCTRL` for the tap delay to be calibrated against a
  reference clock; without it the taps still delay, but the picoseconds per tap
  are process/voltage/temperature dependent and not the datasheet's ~78 ps.
  For finding the centre of an eye that does not matter -- we are looking for
  the tap that maximises margin, not for an absolute delay. It matters a great
  deal if you ever want to quote a number in nanoseconds. Do not.
  """

  use Hw.Component

  param :IDELAY_VALUE, default: 0
  param :IDELAY_TYPE, default: "FIXED"
  param :HIGH_PERFORMANCE_MODE, default: "FALSE"

  input  :idatain, 1
  output :dataout, 1

  # VAR_LOAD control. Unused when IDELAY_TYPE is FIXED -- tie `ld`, `ce`, `inc`
  # low and the block behaves exactly as before.
  #
  # `c` clocks the tap register. It does NOT have to be the 200 MHz reference:
  # that goes to IDELAYCTRL, which calibrates the tap chain independently. `c`
  # only has to be the clock `ld`/`ce`/`inc`/`cntvaluein` are synchronous to,
  # so driving it from the AXI clock keeps the whole tap path in one domain and
  # removes the need to synchronise anything.
  input  :c,          1
  input  :ld,         1
  input  :ce,         1
  input  :inc,        1
  input  :cntvaluein, 5

  # The reason to prefer VAR_LOAD over FIXED even before the tap needs to move:
  # it reads back. CNTVALUEOUT reports the tap the silicon is ACTUALLY using,
  # which turns "did the tap take effect" from an inference into a measurement.
  # With FIXED the only evidence a tap was applied is the bitstream you think
  # you built.
  output :cntvalueout, 5

  blackbox :idelay, "IDELAYE2",
    params: [
      IDELAY_TYPE: :IDELAY_TYPE,
      IDELAY_VALUE: :IDELAY_VALUE,
      DELAY_SRC: "IDATAIN",
      HIGH_PERFORMANCE_MODE: :HIGH_PERFORMANCE_MODE,
      PIPE_SEL: "FALSE",
      CINVCTRL_SEL: "FALSE",
      SIGNAL_PATTERN: "DATA",
      REFCLK_FREQUENCY: 200.0
    ],
    ports: [
      IDATAIN: :idatain,
      DATAOUT: :dataout,
      C: :c,
      LD: :ld,
      CE: :ce,
      INC: :inc,
      CNTVALUEIN: :cntvaluein,
      CNTVALUEOUT: :cntvalueout
    ]
end
