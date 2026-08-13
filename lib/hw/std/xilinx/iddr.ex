defmodule Hw.Xilinx.IDDR do
  @moduledoc """
  Xilinx 7-series input DDR register, in the ILOGIC block beside the pad.

  A source-synchronous LVDS bus like the AD9363's carries one bit per clock
  EDGE, so six pairs deliver twelve bits per `DATA_CLK` period. Recovering that
  needs a register that captures on both edges, and it has to be the dedicated
  ILOGIC one: inferring double-edge capture in fabric logic costs a whole extra
  clock domain and loses the fixed, characterised pad-to-register delay that
  makes the timing closeable at all.

  `DDR_CLK_EDGE` chooses how the two captured bits are presented:

  - `"OPPOSITE_EDGE"` — Q1 and Q2 arrive half a cycle apart, matching the wire
  - `"SAME_EDGE"` — both on the rising edge, but Q2 is a cycle behind Q1
  - `"SAME_EDGE_PIPELINED"` — both on the rising edge, aligned, one cycle of
    latency

  `SAME_EDGE_PIPELINED` would be the natural choice — it is the only mode that
  hands the fabric two aligned bits it can treat as one 2-bit word. **openXC7
  does not support it.** nextpnr-xilinx places and routes the cell happily and
  then rejects it in post-routing legalisation:

      ERROR: unsupported clock edge parameter for cell '...' at ILOGIC_X1Y66:
      SAME_EDGE_PIPELINED. Supported are: SAME_EDGE and OPPOSITE_EDGE

  So the default here is `SAME_EDGE`, which does build. The cost is that Q2
  arrives one clock AFTER the Q1 it was captured alongside, so anything
  reassembling a word has to delay Q1 by a cycle to line them up. That is one
  extra flop per lane and a bit of care in the deserialiser — annoying, not
  expensive.

  Adding `SAME_EDGE_PIPELINED` to nextpnr-xilinx is a small, well-scoped
  contribution: the mode is just an extra register stage inside ILOGIC, and
  prjxray already documents the tile. Worth doing before the deserialiser gets
  complicated enough that the skew handling becomes load bearing.
  """

  use Hw.Component

  input  :c,  1
  input  :ce, 1
  input  :d,  1
  input  :r,  1
  input  :s,  1
  output :q1, 1
  output :q2, 1

  blackbox :iddr, "IDDR",
    params: [
      DDR_CLK_EDGE: "SAME_EDGE",
      INIT_Q1: 0,
      INIT_Q2: 0,
      SRTYPE: "SYNC"
    ],
    ports: [
      C: :c,
      CE: :ce,
      D: :d,
      R: :r,
      S: :s,
      Q1: :q1,
      Q2: :q2
    ]
end
