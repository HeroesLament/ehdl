defmodule Hw.Xilinx.ODDR do
  @moduledoc """
  Xilinx 7-series output DDR register, in the OLOGIC block beside the pad.

  The transmit counterpart of `Hw.Xilinx.IDDR`: presents one bit per clock edge
  on a pad, which is what a source-synchronous LVDS bus like the AD9363's
  transmit port needs.

  ## Unlike `IDDR`, this one has no known reason to fail

  `Hw.Xilinx.IDDR` is broken on this toolchain and documented as unusable —
  prjxray documents only 2 of the 14 `ILOGICE3` site muxes, so the input path
  cannot be configured. The asymmetry is real and was checked rather than
  assumed: for the **output** path, all 12 features `fasm.cc` emits for
  `OLOGICE3_OUTFF` are present in both `segbits_rioi3.db` and `segbits_lioi3.db`,
  the output mux `OLOGIC_Y0.OMUX.D1` is characterised, and the clock reaches
  OLOGIC through a documented pseudo-pip with all six `IOI_LEAF_GCLK*` sources.
  nextpnr transforms `ODDR` into `OLOGICE3_OUTFF` in `XC7Packer::pack_iologic`
  and writes it in `write_iol_config`.

  So the data path is covered end to end. **The tristate path is not.**

  ## Do not drive a tristate with this

  If `Q` drives the `T` pin of an `OBUFT`/`OBUFTDS`, nextpnr creates an
  `OLOGICE3_TFF` cell — and then `write_io` does not list `OLOGICE3_TFF` among
  the types it dispatches to `write_iol_config`. It is not rejected, it is
  *skipped*: **zero OLOGIC bits are emitted and the build succeeds.** The prjxray
  database is not the problem here — it has full TFF coverage — the gap is the
  missing branch in nextpnr's writer, likely because `TQUSED` is the one TFF
  feature absent from the database.

  That is the `DIFF_TERM` failure mode in a different tool: builds clean, wrong
  on silicon, no diagnostic. Until it is fixed upstream, a DDR tristate has to be
  built from fabric logic, the same way the receive path replaced `IDDR` with
  posedge and negedge flops.

  ## Constraints nextpnr enforces

  `Q` must be connected and must fan out to **exactly one** output buffer, or
  packing fails with "has disconnected Q output" / "has illegal fanout on Q
  output". Feeding `OBUFDS` is fine: the fanout check deliberately ignores the
  inverter and the `IOB33S` half of a pseudo-differential pair.

  ## Parameters

  `DDR_CLK_EDGE` is encoded by a single bit, `ODDR.DDR_CLK_EDGE.SAME_EDGE`.
  `"OPPOSITE_EDGE"` is therefore the all-zeros default, **and the string is not
  validated** — a typo silently selects `OPPOSITE_EDGE`. Unlike `IDDR`, where
  `SAME_EDGE_PIPELINED` is rejected outright, here there is no error to notice.

  `INIT` is passed explicitly on purpose. `fasm.cc` writes `ZINIT_OQ` only when
  `INIT == 0`, i.e. it treats 1 as the default, while the yosys stub declares
  `parameter INIT = 1'b0`. The two disagree about which value is implicit, so
  neither is left implicit here.

      instance :tx_d0, Hw.Xilinx.ODDR,
        c: :data_clk, ce: :one, d1: :tx_rise, d2: :tx_fall,
        r: :zero, s: :zero, q: :tx_d0_pad

  **Never validated on hardware.** No design in this repo has ever driven an
  `ODDR` on silicon. See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  # "SAME_EDGE" | "OPPOSITE_EDGE". Unvalidated -- see above.
  param :DDR_CLK_EDGE, default: "SAME_EDGE"
  param :INIT, default: 0
  param :SRTYPE, default: "SYNC"

  input  :c,  1
  input  :ce, 1
  input  :d1, 1
  input  :d2, 1
  input  :r,  1
  input  :s,  1
  output :q,  1

  blackbox :oddr, "ODDR",
    params: [
      DDR_CLK_EDGE: :DDR_CLK_EDGE,
      INIT: :INIT,
      SRTYPE: :SRTYPE
    ],
    ports: [
      C: :c,
      CE: :ce,
      D1: :d1,
      D2: :d2,
      R: :r,
      S: :s,
      Q: :q
    ]
end
