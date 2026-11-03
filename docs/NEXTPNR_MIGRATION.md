# nextpnr-xilinx -> openXC7/nextpnr (himbaechel) migration

2026-09-27.  Status and decisions for moving the LibreSDR flow off
`nextpnr-xilinx`, which openXC7 archived on 2026-09-25 (0.9.8 is the last
release; development continues in `openXC7/nextpnr`, mainline nextpnr with
Xilinx as a himbaechel uarch).  Our fork: `HeroesLament/nextpnr-xilinx`
branch `ourfork`, 16 patches on 13 topic branches over upstream 62839b34.

## Trees on the Mac (`~/src/openxc7`)

| Path | What |
|---|---|
| `nextpnr-xilinx` | the archived tool, our fork; the documented flow (`build.exs`) still uses it by default |
| `nextpnr` | openXC7/nextpnr clone. `main` = upstream; `ourfork` = main + the ported `fix/*` branches below |
| `nextpnr/build`, `nextpnr/build-ourfork` | the two binaries, xc7z020 chipdb only (87 s / 170 s builds) |
| `prjxray-db-517d66a` | worktree of prjxray-db at the revision the new tool's CI pins; its chipdb and FASM must use this db |
| `prjxray-db` | 7a36171, untouched, used by the nextpnr-xilinx flow |

`scripts/openxc7-env.sh` exports `NEXTPNR_HIMBAECHEL` (default the ourfork
binary; `NEXTPNR_HIMBAECHEL_BUILD=build` for upstream) and
`PRJXRAY_DB_HIMBAECHEL`.  `PNR=himbaechel mix run designs/libresdr_radio/build.exs`
uses them; `CARRY=1` drops `-nocarry`; `PNR_TIMING_ALLOW_FAIL=1` demotes a
missed create_clock from error to warning.  The old flow is unchanged.

## What the new tool changes for us

Measured on the radio top with the LTF synchroniser (build_sync3 netlist,
xc7z020, seed default), post-route STA from the new tool:

| Synthesis | axi_clk (100 MHz) | data_clk (32 MHz) | Route |
|---|---|---|---|
| `-nocarry` + `dffunmap` (current flow) | 92.9 FAIL | 69.5 | clean |
| CARRY4 + `dffunmap` | **120.9 PASS** | 70.2 | clean, 958 CARRY4, 45 router iterations |
| CARRY4, real CE nets (no `dffunmap`) | see below | | |

The nextpnr-xilinx estimates for the same netlist (78-91 MHz on 12 seeds)
were placement-only; the new tool's pre-route estimate was 140 MHz and the
routed figure 93, so neither estimator is worth reading.  Only the post-route
number is.  The `-nocarry` critical path is a 22-level LUT ripple (3.5 ns
logic, 7.3 ns routing) in an AXI-domain adder/compare; CARRY4 removes it.

Open items in the new tool, from its own `docs/xilinx-porting/`: LUT/FF cell
timing is stubbed in the chipdb generator (interconnect is a measured table,
`delay_matrix.cc`), the fork's carry-O relocation legality has not been
ported, `vc707-carry` (fabric taps on sum and carry-out) is a recorded known
routing failure.  Nothing yet on silicon from this tool: that is the next gate,
on `hp_loop` first, then the radio.

## Fork patches: disposition

`git cherry` finds no byte-identical counterpart upstream for any of the 16.
By topic, against both the archived tool's `main` (218 commits past our base)
and the new tree:

| Fork branch | Upstream state | Action |
|---|---|---|
| fix/clock-router-arc-interleave | absent in both; `route_clocks()` in the new tree is the same net-at-a-time loop | **ported** (`fix/clock-arc-interleave`). Measured need: 0/368 seeds on the radio without it |
| fix/router-reserve-parallel-pips | absent; mainline router2 has the pip-count bug in both the sink and the driver walk | **ported** (`fix/router2-reserve-distinct-wires`), both walks |
| tool/router-arc-diag (2 commits) | absent | **ported** as one (`fix/router2-explain-arc`) |
| fix/iserdes-ofb-tieoff | new tree accepts OSERDES-OFB-fed ISERDES but does not drop constant OFB/OCLK/OCLKB | **ported** (`fix/iserdes-const-tieoffs`) |
| fix/idelay-requires-idelayctrl | archived main went the other way (IDELAYCTRL without delays = warning, #60); the delay-without-controller case is unhandled in both | **ported** (`fix/idelay-requires-idelayctrl`) |
| fix/ilogic-iffdelmux | absent; new tree writes IDELMUXE3 unconditionally for ILOGICE3_IFF | **ported** (`fix/ilogic-iffdelmux`) |
| fix/bram-x9-parity-guard | absent | **ported** (`fix/bram-x9-parity-guard`), once per RAMB36 (lower half) |
| fix/cmt-startup-wait | absent | **ported** (`fix/cmt-startup-wait`) |
| fix/cmt-clkout-counters (DUTY_CYCLE + PLL frac refusal) | absent; both `// FIXME: variable duty cycle` still there | **ported** as one (`fix/cmt-clkout-counters`) |
| fix/mmcm-frac-power-reg | new tree writes POWER_REG 0xFFFF unconditionally, which covers the fractional case | not needed |
| fix/cmt-zinv-polarity | **contested.** New tree keeps the un-negated form with silicon evidence (Sonata: the negation made the PLL run only while reset was held). Archived main fixed the GND-tied PWRDWN case differently (400726f4: disconnect + IS_PWRDWN_INVERTED). Our evidence was a GND-tied RST that never locked; that is consistent with the constant not being routed to the CMT pin in nextpnr-xilinx of the time (pin floats high) and our negation inverting the float. | **not ported.** Re-test a GND-tied RST/PWRDWN on the new tool before touching it |
| fix/postplace-controlset-repair | control sets are part of slice validity in the new placer (`xilinx_place.cc`, heap `ff_control_set_groups`) | not applicable as written; watch for mixed-clock slices |
| fix/frozen-tile-validity-strength | no frozen-tile fast path in the new placer; upstream carries this as an unmerged branch | not applicable |
| docs: branch layout | | regenerate for the new repo when the branches settle |

Patch files: `.scratch/np_patches/` (from the container port), applied with
`git am` so authorship is preserved.  Each is an independent branch off
`main`; `ourfork` merges all nine.  None has been pushed; the fork on GitHub
(`HeroesLament/nextpnr`) does not exist yet.

## Next

1. Silicon: `hp_loop` through `PNR=himbaechel CARRY=1`, load on dr-b, run the
   HP0 loopback check.  Then the radio top: TX DMA ring + detector + sync.
2. If CE nets route (below), drop `dffunmap` too: it costs one LUT per FF on
   every enabled register (7k LUTs in the LTF synchroniser's delay lines).
3. Push the nine branches to a `HeroesLament/nextpnr` fork and open PRs
   upstream; the clock-arc interleave and the router2 reservation fix are the
   ones with measured impact.
