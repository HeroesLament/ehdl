defmodule Hw.Xilinx.OBUFDS do
  @moduledoc """
  Xilinx 7-series differential output buffer.

  The transmit counterpart of `Hw.Xilinx.IBUFDS`, and the primitive an LVDS
  transmit port needs. On this toolchain it works, but not in the way the name
  suggests, and the one requirement that matters is unenforced by every tool in
  the flow.

  ## It is not a differential output buffer here

  nextpnr-xilinx has no true differential output bel — the code says so:
  `// FIXME: true diff outputs`. `decompose_iob` turns one `OBUFDS` into three
  cells: an `OBUF` on `IOB33M/OUTBUF` of the master pad, an inverter on
  `IOB33S/O_ININV` of the slave, and a second `OBUF` on `IOB33S/OUTBUF`. The
  differential behaviour comes from `RIOB33.OUT_DIFF` plus `LVDS_25.OUT` and
  `LVDS_25.DRIVE.I_FIXED`, which put the pair into a real LVDS driver mode.

  That works, and the `IOSTANDARD` is what separates "an LVDS driver" from "two
  ordinary LVCMOS drivers, one of them inverted".

  ## The `IOB_Y0` question, checked and answered

  The differential-output features exist **only for `IOB_Y0`**. `IOB_Y1` has no
  `LVDS_25.OUT`, no `LVDS_25.DRIVE.I_FIXED` and no `TMDS_33.*` features at all in
  `segbits_riob33.db` / `segbits_liob33.db`, and `fasm.cc` matches the database by
  gating those writes on `yLoc == 0`.

  That reads like a trap — pick the wrong half of a tile and get a bitstream with
  no differential enable. **It is not, and the reasoning is worth keeping** because
  the first draft of this module claimed it was:

      tile_type_RIOB33.json:  X0Y0 -> IOB33S,  X0Y1 -> IOB33M
      fasm.cc:1084            yLoc = 1 - ioLoc.y

  `IOB33M` — the master, the P pin — is site-in-tile Y1, and `yLoc` is the
  *inverse* of the site index. So the master is always `IOB_Y0`, which is exactly
  where nextpnr puts the driving `OBUF` (`<site_p>/IOB33M/OUTBUF`) and exactly
  where the enable bits live. The database, the writer and the packer agree, and
  there is nothing to get right per-pin.

  The real constraint is a weaker one: the two pins must be the P and N of **one
  differential pair in the same tile**, because `decompose_iob` places the inverter
  on `<site_n>/IOB33S/O_ININV` and the partner lookup indexes the tile by
  `1 - ioLoc.y`. Two unrelated pins fail at placement, which is a loud failure and
  therefore fine.

  Recording this because the error was nearly made in the other direction from
  usual. This repo's habit is to trust a claim that turns out to be false; here a
  toolchain detail was true (`bits only exist for Y0`) and the hazard inferred from
  it was false. Both are wrong answers. `yLoc` not being the site index is the kind
  of thing that has to be read rather than assumed.

  ## Condition that is real: `LVDS_25` or `TMDS_33`, and nothing else

  Those are the only two `IOSTANDARD` values with encodable differential-output
  features on this part. `xc7z020clg400` has no `RIOB18`/`LIOB18` tiles — every IO
  is IOB33 / High-Range — so the `LVDS` and `SSTL*` High-Performance paths in
  `fasm.cc` are unreachable. Anything else falls through to the single-ended
  `DRIVE`/`SLEW` chain, silently, and you get two ordinary LVCMOS drivers with one
  inverted. That is electrically not LVDS, and it builds without complaint.

  `IOSTANDARD` is therefore **hardcoded, not a parameter.** `Hw.Xilinx.IBUFDS`
  sets the same precedent. A parameter here would be a parameter whose wrong
  values are accepted and discarded, and this repo has already paid for
  `DIFF_TERM` and `SAME_EDGE_PIPELINED` behaving that way. For `TMDS_33`, copy
  this module rather than widening it — the copy is honest about being a different
  configuration.

  Note also that `DIFF_TERM` remains absent from nextpnr entirely, confirmed again
  at this database revision. It is input-side so it does not affect this
  primitive, but `Hw.Xilinx.IBUFDS` still passes it and it is still ignored.

      instance :tx_d0_buf, Hw.Xilinx.OBUFDS,
        i: :tx_d0, o: :ad9363_tx_d0_p, ob: :ad9363_tx_d0_n

  **Never validated on hardware.** An earlier claim in `AGENTS.md` that `OBUFDS`
  was "verified working" was wrong — there was no EHDL wrapper, so it had never
  been instantiated at all. See the verification tiers there.
  """

  use Hw.Component

  # "SLOW" | "FAST". Encoded through the ordinary single-ended SLEW bits.
  param :SLEW, default: "SLOW"

  input  :i,  1
  output :o,  1
  output :ob, 1

  blackbox :obufds, "OBUFDS",
    params: [
      IOSTANDARD: "LVDS_25",
      SLEW: :SLEW
    ],
    ports: [
      I: :i,
      O: :o,
      OB: :ob
    ]
end
