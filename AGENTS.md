# AGENTS.md — EHDL

Elixir HDL. Elaborates `Hw.Component` modules to Verilog, simulates them, and
(for Xilinx 7-series) drives an openXC7 flow with no vendor tools anywhere.

## Running the test suite

```sh
ERL_FLAGS="+t 8000000" mix test
```

**The flag is not optional.** Without it the VM dies partway through with
`no more index entries in atom_tab (max=1048576)` and writes a crash dump.
Something mints atoms per elaboration — probably generated signal names — and
the full suite exhausts the default table. This is pre-existing and unrelated
to any recent change; it reproduces identically on a stashed baseline.

The suite takes **~500 s** (~446 s of it sync) — **but expect it to get
substantially slower**, because the 41-failure cluster below used to bail out of
`setup` in milliseconds and now actually simulates. The eight repaired modules
alone take upwards of 20 minutes of real work.

### The 41-failure cluster: fixed, and it was never a simulator bug

For most of this repo's history the suite reported **41 failures** across
`HelloBoard.CDCTest`, `HelloBoard.PHYTest`, `HelloBoard.LoopbackTest`,
`HelloBoard.UARTTXTest`, `HelloBoard.UARTRXTest`, `HelloBoard.ResetTest`,
`PHYDebugTest` and `Hw.USBEnumWindowsTest`, all exiting `GenServer.call ... no
process` out of `Hw.Sim.force_reg/3` in setup. That was written off as a
pre-existing cluster to be worked around.

It was one cause, and a mundane one. `HelloBoard.Top` replaced its `ResetSync`
component with `Hw.ReEnum` — deliberately, and the design says so: *"Replaces the
old ResetSync + rst_arm indirection."* Eight test modules each carried their own
copy of "force the reset synchroniser to its released state", naming
`:rst_sync` and four `rst_sync_*` registers. After the refactor the string
`rst_sync` does not appear anywhere in `designs/hello_board/top.ex`. The tests
were forcing an entity that no longer existed.

Two things kept that invisible for so long, both now fixed:

- `force_reg/3` called an unregistered via-tuple, so the error was `no process` —
  naming neither the entity nor the design. It now raises listing the entities
  that do exist, which turns the whole cluster into one legible sentence:
  `no entity :rst_sync in this design / entities : :_top_, :cdc, :diag, :phy,
  :pll, :prog, :sie, :uart_rx, :uart_tx`.
- Unknown *register* keys were merged in silently by
  `handle_call({:force_reg, ...})` and written to ETS where nothing reads them, so
  a stale signal name forced nothing and said nothing. Those are validated too,
  with a hint for the prefix mistake — which the function's own docstring used to
  demonstrate, showing `%{dev_state: 3}` where the register is `:cdc_dev_state`.

The repair itself is `HelloBoard.SimSetup.release_reset/1`, in
`designs/hello_board/`, next to the design that owns the knowledge instead of
copied into eight test files. That duplication is the actual defect here: one
refactor, eight places to update, and the cost was the suite's usefulness as a
gate for months.

**The lesson is about the write-off, not the bug.** "41 pre-existing failures,
all the same cluster" was recorded as an environmental fact and routed around,
including in this file. Nobody read the first stack trace. A failure cluster with
a single shared symptom is a *strong* hint of a single shared cause, which makes
it cheap to fix, not safe to ignore.

**Take a baseline before you touch anything.** `git stash`, run the suite, count
failures, unstash. Twice in this repo's history a change has been blamed for
failures that were already there — and once, a cluster that was nobody's fault
was assumed to be nobody's problem.

## The simulator runs at ~4 ticks/s, and 87% of that is wasted work

Measured on `HelloBoard.Top`, `_prim/tick_bench.exs` and `_prim/tick_reds.exs`:

    200 clk_48 ticks in 53.0 s          ->    4 ticks/s   (265 ms per tick)

    reductions over 5 ticks, by process
      {:entity, :_top_}    14,969,085     <- 87%
      {:entity, :sie}         981,491
      {:entity, :cdc}         853,222
      {:entity, :phy}         270,549
      everything else       < 100,000

`_top_` is 87% of simulation cost. It holds **40,455 of the design's 40,747 ops**,
of which 40,361 are combinational, and `build_env/1` takes the `:_top_` branch
that materialises the **entire 40,770-signal ETS table** into a map via
`:ets.tab2list` + `Map.new`. `_top_` is an ordinary entity as far as the clock is
concerned, so all of that runs on **every clock edge**.

### Why it is waste rather than cost

`partition_entities/3` copies ops into per-entity sets but deliberately leaves
them in `_top_` too — the comment says *"_top_ retains all its ops so it can still
settle cross-entity comb."* That was true when written. `Hw.Sim.Clock` has since
gained `cross_settle_ops` / `cross_settle_inputs`, an inline settle in phase 2b
that reads *"only the ~5 ETS signals needed"* and evaluates *"the ~9-op closure"*
synchronously in the clock process before notifying the arbiter. That superseded
`_top_`'s reason to hold the whole design — and nobody removed the retention.

So the design is evaluated twice per edge: once distributed across entities where
the work is small (sie 3194 ops, cdc 3427, phy 1025), and once in its entirety in
`_top_`, to compute cross-entity signals the clock has already computed in nine.
Note `handle_info({:commit_done, ...})` even resolves `top_pid` and then never
uses it — the vestige of the path that was replaced.

### What this has cost

This is why the project has no simulation of the fabric against a modelled
AD9363, and therefore why *"the instrument is the device under test"* has happened
three times. At 4 ticks/s:

- one 9600-baud UART bit at 48 MHz is 5000 ticks — **21 minutes**
- one byte is 50,000 ticks — **3.5 hours**
- one 802.11ah 1 MHz OFDM symbol at 640 cycles — **2.7 minutes**

It is also the direct cause of the 17 remaining test failures, which are
`ExUnit.TimeoutError` in `Hw.Sim.Testbench.tick/3`, not wrong expectations. The
tests are correct and the simulator cannot finish them inside 120 s. The eight
repaired `HelloBoard` modules take 56 minutes for 45 tests.

### The fix, in order of confidence

1. **Stop `_top_` evaluating its full comb set on every edge.** It still needs its
   94 registers committed, and it still needs the full set for explicit
   `Entity.eval_now(:_top_, ...)` on the testbench path (`Testbench.set/3`,
   `force_reg/3`). But per-edge it should evaluate only what feeds its own regs
   and cross-entity signals — which is exactly what `copy_needed_ops/4` already
   computes for every other entity.
2. **Make `build_env(:_top_)` use targeted reads.** The non-`_top_` clause three
   lines below already does it: 723 `spec.inputs` instead of 40,770 signals.
3. Only then look at dirty-tracking. `State.mark_top_dirty/1` and
   `clear_top_dirty/1` exist and suggest someone started down this road.

Do **1** and measure before doing anything else; if `_top_` is 87%, removing most
of it is most of the win.

### A method note

The first guess — `_top_` re-evaluating everything — was right. Reading
`Hw.Sim.Clock` and finding `cross_settle_ops` then argued it away, because an
optimisation that exists reads like an optimisation that is used. The reduction
counts settled it in one run. **Per-process reduction deltas are the cheap tool
here**, and they need no profiler: this Erlang build has no `tools` application,
so `:eprof` and `:fprof` are both unavailable.

## DSL gotchas that cost real time

- **`^` is not XOR.** Elixir's `^` is the pin operator; `a ^ b` elaborates to
  `Unknown defhw expression: ^/1`. Use `bxor(a, b)`. (`^^^` also maps to bxor.)
- **Sized literals inside a concat are not parsed.** `{0::22, foo}` fails with
  `Unknown defhw expression: ::/2`. Declare a named zero wire and concat that.
- **Instance parameters go in the port map**, keyed by param name:
  `instance :spi, Hw.SPI.Master, CLK_FREQ: 100_000_000, clk: :axi_clk, ...`
- Slices are `sig[hi..lo]`, single bits `sig[3..3]`.
- **A `clock` needs a matching `wire` declared before it, or it becomes a
  top-level input port.** `wire :axi_clk, 1` then `clock :axi_clk, freq: 100.0`
  gives an internal net a `BUFG` can drive; omitting the `wire` makes `axi_clk` a
  module port, and nextpnr then rejects it with `port axi_clk of type PAD has no
  IOSTANDARD property` — which reads like a constraints problem and is not one.
- **An instance parameter of `false` is silently ignored; `0` is fine.** This
  entry previously claimed `0` was the broken case. **That was wrong, and the
  retraction is the useful part: in Elixir `0` is truthy.** Only `nil` and
  `false` are falsy, so `Map.get(p, :value) || p.default` always resolved
  `PREG: 0` correctly. Verified by reverting the change and re-running
  `test/xilinx_primitives_test.exs` — 17/17 still passed, including the
  `.CREG(0)` assertions.

  The real defect is narrower: `false` is the one falsy value that can arrive, so
  `STARTUP_WAIT: false` against `default: "TRUE"` resolved to `"TRUE"` in
  silence.

  Preserving `false` turned out not to be the fix either — it emits
  `.STARTUP_WAIT(false)`, a bare Verilog identifier yosys rejects as a
  non-constant parameter, pointing at generated code. **A boolean parameter value
  is now rejected at elaboration**, where the message can name the parameter, the
  component and the instance, and suggest `"FALSE"`. Verilog parameters take
  numbers and strings; a boolean is always the "reached for Elixir's `false`"
  mistake.

  Two lessons worth more than the fix. **Falsy-zero intuition is imported from
  JavaScript and Python and does not survive contact with Elixir** — check `0 ||
  1` before writing that comment. And a claimed bug should be demonstrated by
  reverting the fix and watching a test fail; when the test passes either way,
  there was no bug. Passing tests around a no-op change read exactly like
  confirmation, which is how this one nearly ended up recorded as fact.
- **An unresolvable parameter reference is now rejected at elaboration.** A bare
  atom in a `params:` list is a reference to a `param` declaration; a misspelling
  used to emit as bare Verilog text (`.INIT(REAL_NAEM)`), and a `param` declared
  with no `default:` that no instance set used to reach the emitter as a
  `%Param{}` struct and die in `to_string/1` with `protocol String.Chars not
  implemented`. Both now raise naming the parameter, the component, the instance
  and the declared alternatives. Checked before making it loud: zero atom-valued
  blackbox params across `lib/`, `designs/` and `examples/` failed to resolve, so
  nothing relied on the pass-through.
- **A blackbox param value is emitted quoted if it is a binary and bare
  otherwise**, via `to_string/1`. Floats are fine (`10.0` -> `10.0`), so real
  Xilinx parameters work. There is **no way to emit an unsized-literal parameter**
  such as `48'h3FFFFFFFFFFF`: a string would come out quoted and become a string
  param, and a bare integer that wide overflows Verilog's 32-bit default. This has
  not bitten yet because the only affected parameters (`DSP48E1`'s `MASK` and
  `PATTERN`) are unusable for other reasons, but a `LUT` or `RAMB*` `INIT` would
  need an escape hatch in `emit_blackbox/2`.

## Elaborator: `defhw` inlining

Inlining is a **fixpoint**, not one pass. A `defhw` whose body calls other
`defhw`s — including from inside an `hdl_case` branch, which is the ordinary way
to write a register-write dispatcher — used to leave the inner calls as
`:defhw_call` nodes that nothing downstream matches. `find_all_assigned` did not
see them, `build_mux_tree` never visited them, the emitter had no clause. The
result elaborated, validated, synthesised, placed, routed, and **silently
dropped every write on real hardware**.

Guards now in place, do not remove them:

- `assert_no_defhw_calls!/2` runs after inlining in both `elaborate_logic_block`
  clauses and raises if any call survived. This is the backstop for future node
  types whose bodies the traversal does not know to walk.
- `check_defhw_cycle!/2` raises on self- or mutual recursion, which previously
  hung the build.
- `elaborate_fsm/8` inlines **before** `find_all_assigned/1` collects reset
  targets. Otherwise a register assigned only inside a `defhw` is missing from
  the reset branch, holds across reset instead of returning to `init:`, and
  splits the 7-series control set.

## Emitter: `Ops.Mux` is first-match-wins, everywhere

`Ops.Mux.cases` is an ordered, priority-encoded list. All four lowerings now
agree: the ternary form (≤2 arms), the Elixir interpreter (`Enum.find_value`),
the Rust NIF (`iter().find_map`), and `emit_casez`.

`emit_mux_always` (>2 arms) used to emit a flat run of independent `if`s over a
pre-assigned default, making the **last** match win — a sim/synth split. A
trailing always-true arm (an `<<_::N>>` catch-all) clobbered every specific arm
above it in hardware only, which silently pinned the whole USB CDC dispatch.
`emit_casez` reversed its arms to stay bug-compatible.

If you touch mux lowering, the load-bearing tests are in `hdl_case_test.exs` and
they assert on **emitted Verilog text**, not simulation. Simulation was always
right; only the Verilog was wrong, so nothing that runs in a sim can catch a
regression here.

## openXC7 flow (xc7z020clg400-1)

Three-stage yosys. The middle stage is not optional — without it the packer
produces set/reset routing neither router can resolve.

```sh
yosys -p "read_verilog -sv top.v; \
  synth_xilinx -flatten -abc9 -arch xc7 -nocarry -top top -run begin:map_cells; \
  dffunmap; opt_clean; \
  synth_xilinx -arch xc7 -nocarry -top top -run map_cells:; \
  write_json top.json"

nextpnr-xilinx --chipdb ~/src/openxc7/chipdb/xc7z020.bin \
  --xdc design.xdc --json top.json --fasm top.fasm --freq 100 --seed 2

DB=~/src/openxc7/nextpnr-xilinx/xilinx/external/prjxray-db/zynq7
PYTHONPATH=~/src/openxc7/prjxray ~/src/openxc7/venv/bin/python \
  ~/src/openxc7/prjxray/utils/fasm2frames.py \
  --part xc7z020clg400-1 --db-root $DB top.fasm > top.frames
~/src/openxc7/prjxray/build/tools/xc7frames2bit \
  --part_file $DB/xc7z020clg400-1/part.yaml --part_name xc7z020clg400-1 \
  --frm_file top.frames --output_file top.bit
```

**`--seed 2` matters.** With two BUFGs in a design, the default seed (and 3, and
7) fails with `Failed to route arc N of net 'data_clk', from BUFGCTRL_X0Y17 to
SLICE_...`. Seed 2 routes. Global clock routing with multiple BUFGs is fragile
here, and the failure looks like a design problem when it is not.

`-nocarry` costs real performance — it replaces hardware carry chains with LUT
logic on exactly the arithmetic paths that tend to be critical. Removing the
need for it would be a genuine upstream contribution.

## openXC7 gaps found the hard way

- **`IDDR` `SAME_EDGE_PIPELINED` is unsupported.** nextpnr places and routes it,
  then rejects it in post-routing legalisation. Only `SAME_EDGE` and
  `OPPOSITE_EDGE` work. `SAME_EDGE` presents Q2 one clock after the Q1 it was
  captured with, so anything reassembling a word must delay Q1 by a flop.
- **`DIFF_TERM` is silently ignored.** Zero occurrences in nextpnr-xilinx
  source, zero termination features in emitted FASM. prjxray documents only
  three DIFF-related features for `RIOB33`, all `IN_DIFF` receiver enables — the
  on-die 100 Ω LVDS termination does not appear to be characterised at all.
  This is a **prjxray fuzzer gap**, not just a nextpnr omission. It builds
  clean and is wrong on silicon, which is the worst failure class here.
- **`IDDR` capture does not work. Root cause found.** The ILOGIC *combinatorial*
  path works; the ILOGIC *input flip-flop* path does not.

  Evidence, from `designs/libresdr_radio` built and read back as FASM:

  - Every `IBUFDS` gets identical IOB config — `IOB_Y0/Y1.LVDS_25_SSTL135_SSTL15.IN_DIFF`
    plus `IN_ONLY`. `DATA_CLK` (`RIOB33_X73Y71`) is configured exactly like the six
    data pairs and **is received correctly** at both 7.679 and 15.996 MHz. So the
    differential receiver and the pin constraints are fine.
  - `DATA_CLK` leaves its ILOGIC via the combinatorial output
    (`RIOI3_X73Y71.RIOI_I2GCLK_TOP0.IOI_ILOGIC0_O`). The seven `IDDR`s leave via
    `IOI_ILOGIC0_Q1` / `Q2`. That is the only difference between the working path
    and the dead one.
  - The routing pip `RIOI_ILOGIC0_D.RIOI_I0` is present on all seven, so the IOB
    output does reach the ILOGIC D pin.

  The reason the IFF path cannot work: **prjxray documents 2 of the 14 ILOGICE3
  site muxes for RIOI3.** Missing are `IFFMUX`, `IMUX`, `D2OBYP_SEL`,
  `D2OFFBYP_SEL`, `CLKINV`, `CLKBINV`, `DINV`, `ZHOLD_IFF_INV`, `ZHOLD_FABRIC_INV`,
  `CE1USED`, `SRUSED`, `REVUSED` — that is, precisely the muxes that select what
  feeds the input flip-flops and on which edges they clock. nextpnr cannot emit
  bits that do not exist in the database, so they take the all-zeros default.
  **Correction:** an earlier note here claimed "`OLOGICE3` is worse: 1 of 19".
  That was wrong — an artefact of a careless script that matched feature names
  against the wrong tile prefix. Every feature nextpnr actually emits for `ODDR`
  *is* in the database (`ODDR.DDR_CLK_EDGE.SAME_EDGE`, `ODDR.SRUSED`,
  `ODDR_TDDR.IN_USE`, `OQUSED`, `OSERDES.DATA_RATE_*`, `OSERDES.SRTYPE.SYNC`,
  `ZINIT_OQ`, `ZINV_CLK`, `ZSRVAL_OQ`, `IS_D1/D2_INVERTED`), and OLOGIC's output
  mux `OMUX.D1` is characterised.

  That asymmetry is the actual finding: **the output path's mux is documented and
  the input path's is not.** So the gap is specifically ILOGIC input selection,
  not "the IO logic tiles are uncharacterised". `ODDR` has no known reason to
  fail, and TX is not obviously blocked.

  This is a **prjxray fuzzer gap**, the same class as `DIFF_TERM` — it builds
  clean and is wrong on silicon. Fixing it properly means writing a fuzzer for
  the ILOGIC input muxes, which is a genuine and well-scoped upstream
  contribution.

  **Workaround that needs none of that:** capture DDR in fabric instead. The
  combinatorial path out of `IBUFDS` demonstrably works, so take the
  single-ended signal into two ordinary fabric flops, one on `posedge data_clk`
  and one on `negedge`. `Hw.Xilinx.IDDR`'s own moduledoc argues against this —
  it costs a clock domain and loses the characterised pad-to-register delay —
  but that argument was written for a fast bus. At a 16 MHz `DATA_CLK` with
  4000 fabric cycles per OFDM symbol, it is affordable, and it is the only path
  to captured samples that does not start with a fuzzer.

- Verified **on hardware**: `IBUFDS` (receives `DATA_CLK` correctly),
  `OBUF`, `BUFG`, `PACKAGE_PIN` and `IOSTANDARD` via `--xdc`, `LVDS_25`,
  `LVCMOS25`.
- Verified as **"builds, and the configuration bits are in the bitstream"**:
  `DSP48E1`, `PLLE2_BASE`, `ODDR`, `OBUFDS`. This is a tier the repo did not
  previously have, and it exists because "it builds" is the standard that burned
  us three times — `DIFF_TERM`, `SAME_EDGE_PIPELINED` and tristate `ODDR` all
  place and route cleanly and write no bits. `designs/prim_check` takes all four
  through yosys, nextpnr (seed 1), `fasm2frames` and `xc7frames2bit`, and the
  FASM is then checked for the features each is supposed to produce. It is not a
  hardware measurement and does not claim to be. What it does establish is
  stronger than an exit status, because the emitted values can be read back and
  cross-checked against what was asked for:

      PLLE2_ADV.CLKFBOUT_CLKOUT1_HIGH_TIME/LOW_TIME = 4/4   <- CLKFBOUT_MULT: 8
      PLLE2_ADV.CLKOUT0_CLKOUT1_HIGH_TIME/LOW_TIME  = 2/2   <- CLKOUT0_DIVIDE: 4
      PLLE2_ADV.DIVCLK_DIVCLK_NO_COUNT[0]                   <- DIVCLK_DIVIDE: 1
      DSP48.DSP_0.ZADREG[0], ZCREG[0], ZDREG[0]             <- ADREG/CREG/DREG: 0
      OLOGIC_Y0.ODDR.DDR_CLK_EDGE.SAME_EDGE, OQUSED,
        OSERDES.DATA_RATE_OQ.DDR, SRTYPE.SYNC, ZINIT_OQ
      RIOB33.OUT_DIFF, IOB_Y0.LVDS_25.OUT, .DRIVE.I_FIXED

  Two of those lines are worth dwelling on. The three `Z*REG[0]` bits are exactly
  the three registers overridden to 0 and no others, which proves parameter
  overrides reach the bitstream. It was briefly written up here as confirming a
  `build_param_map` fix; it does not, because there was no bug to fix — see the
  `false`-vs-`0` entry above. **Evidence that the behaviour is right is not
  evidence that a change caused it.** And the differential-output bits landed on
  `IOB_Y0` of `RIOB33_X73Y63` with `ddr_p` constrained to V16, the M/P site —
  confirming empirically what `Hw.Xilinx.OBUFDS`'s moduledoc reasons out from
  `tile_type_RIOB33.json`.

- **Never on hardware, and do not upgrade these without a measurement**: all four
  of the above, plus `IDDR` (`libresdr_radio` used it and it was broken;
  `lvds_spike` is marked not for loading). No design in this repo has ever driven
  an `ODDR`, an `OBUFDS` or a fabric-generated clock on silicon, or computed
  anything in a `DSP48E1`. The earlier "verified working" list conflated "places
  and routes" with "works". `designs/prim_check` is explicitly **not for
  loading** — it drives the AD9363's receive pads as outputs.

## Zynq-specific rules

**Never read `0x4000_0000` before `/sys/class/fpga_manager/fpga0/state` reads
`operating`.** The AXI interconnect has no timeout: a read into unconfigured PL
does not fault, it hangs the CPU with no oops and no recovery short of a power
cycle. No process boundary, NIF sandbox or language prevents this. Only not
issuing the access prevents it.

`M_AXI_GP0` is AXI3, not AXI4-Lite. `RLAST` must be driven or reads never
retire — the symptom is a hang with the bitstream loaded, clock running, level
shifters up and everything else looking healthy. `AWID`/`ARID` must be captured
and echoed on `BID`/`RID`. `AWSIZE`/`ARSIZE` are 2 bits on Zynq GP ports;
`Hw.PS7` still declares them as 3 (known, unfixed).

`FCLK_CLK0` is programmed by `ps7_init`, **not by the bitstream**. A design can
be correctly loaded and appear completely dead if the clock gate is shut
(`0xF8000178`).

## Designs in this repo

- `designs/libresdr_bringup/` — minimal PS7 + AXI4-Lite proof of life
- `designs/lvds_spike/` — toolchain probe for `IBUFDS` + `IDDR`; not for loading
- `designs/libresdr_radio/` — the live one: PS7 + AXI + SPI master + LVDS RX

`designs/*/build.exs` is stale — it predates the three-stage recipe and the
seed. Use the commands above.

## `designs/libresdr_radio` — STATUS3 crossing: FIXED by the capture buffer

Superseded. `STATUS3` now carries the read port of a 1024 x 14 snapshot buffer
(`memory :cap, ..., sync_read: :axi_clk`, inferred as one RAMB18E1) rather than
the live `sample_word`. Write port on `DATA_CLK`, read port on `AXI_CLK`; readout
only after capture halts, so the write side is idle and the contents are static.
`CTRL2[9:0]` is the read address and `CTRL2[16]` the arm toggle.

The original problem, kept for the reasoning:

## (historical) STATUS3 was an unsynchronised crossing

`sample_word` and `frame_pair` are registers in the `DATA_CLK` domain fed
straight into `status3` in the `axi_clk` domain. No synchroniser, no gray code,
no capture handshake — unlike `dclk_count`, which was deliberately reduced to a
single toggling bit before crossing. Reads can return a word the register never
held, and successive reads are thousands of `DATA_CLK` periods apart at
unrelated phase, so they are not consecutive samples.

Anything needing sample order — a PRBS check, a decoder, any DSP — needs a
capture buffer in the `DATA_CLK` domain first, read out over AXI once halted.

`mix hw.check`'s `cdc_crossing` rule does not flag this. Worth understanding
why before trusting it on the next design.

## `IDDR` is confirmed broken on hardware; use fabric DDR capture

Confirmed by replacing it. `designs/libresdr_radio` now captures DDR with two
ordinary fabric flops per lane (`posedge` + `negedge` on `data_clk`) instead of
`Hw.Xilinx.IDDR`. Changing *only* the capture logic changed the captured word
from a constant `0xFC0` to a constant `0x659`, and — decisively —

    rise_d0..d5 = 1,0,0,1,1,0
    fall_d0..d5 = 1,0,0,1,1,0     <- identical, as a DC input must give

`rise == fall` is what physics requires for a static input. The `IDDR` gave
`rise = 0` and `fall = 1` on all seven pairs simultaneously, which is impossible
for any DC level and is the signature of flip-flops not connected to their pad.
Root cause is the prjxray gap documented above (2 of 14 ILOGICE3 site muxes).

`Hw.Xilinx.IDDR` is left in the stdlib but **must not be used on this toolchain**
until the ILOGIC muxes are characterised. The fabric version is also the
known-good reference instrument to fuzz the IDDR *against*.

### Two build notes from the conversion

- **The fabric-DDR variant needs `--seed 1`, not `--seed 2`.** Seed 2 fails with
  `Failed to route arc 15 of net 'data_clk', from BUFGCTRL_X0Y17 to
  SLICE_X33Y109/CLKINV_OUT`. Negedge flops add clock-inverter loads to the global
  net and make the documented `data_clk` routing fragility worse. Sweep seeds
  when this happens; 1 routes cleanly. This is the third distinct seed-dependent
  routing failure in this repo — treat the seed as a build input, not a constant.
- **`clock :name, edge: :negedge, domain: :other` works** and is the clean way to
  express a second edge on one net. Declare a wire equal to the clock, give it a
  negedge clock declaration, and set `domain:` to the original so the analysis
  passes treat transfers between them as source-synchronous rather than as a CDC.

## Vendor-free vs Vivado: where the gaps actually are

Assessed against the prjxray database and nextpnr-xilinx source, plus what this
project has now run on hardware.

**Confirmed broken:**

- **ILOGIC input flip-flop path** (`IDDR`, and by extension `ISERDES`). 2 of 14
  ILOGICE3 site muxes documented; the missing ones are exactly the input
  selectors. Confirmed on silicon, worked around with fabric DDR capture. This
  also blocks `ISERDES`, which is the only way to run the AD9363 interface much
  above the current 16 MHz — so it caps interface rate, not function.

**Real, measured as not limiting here:**

- **`DIFF_TERM` on RIOB33.** No on-die termination features characterised.
  Measured via a software eye diagram: 94/256 delay cells give zero errors at
  16 MHz DATA_CLK, so termination is not the constraint at HaLow rates. Unknown
  at 61.44 MSPS.
- **`DIFF.ZIBUF_LOW_PWR` is never emitted for RIOB33** — only for RIOB18 and the
  LEFT-HP bank. So `IBUF_LOW_PWR=FALSE`, the high-performance input buffer, is
  unreachable on High-Range banks. Same bucket: irrelevant now, relevant if the
  interface ever runs fast.

**Toolchain friction rather than missing capability:**

- **`-nocarry` is required**, replacing hardware carry chains with LUT logic. This
  is the one that will actually hurt: it lands on exactly the arithmetic paths an
  FFT and a CORDIC are made of.
- **Global clock routing with two BUFGs is seed-dependent, and it is a capacity
  wall rather than luck.** Four consecutive revisions of `libresdr_radio` needed
  seeds 2, 1, 5 and 25. That last one is the alarming number: the fourth revision
  widened the capture BRAM from 14 to 26 bits (one RAMB18 to two) and then
  **seeds 1..23 all failed and exactly one seed in 24..400 succeeded.**

  Every failure is identical: `Failed to route arc N of net 'axi_clk', from
  BUFGCTRL_X0Y16/O to SITEWIRE/SLICE_X33..34,Y106..113/CLKINV_OUT`. It is
  preceded in the log by

      Info:     routing clock 'axi_clk'
      Info:             failed to find a route using dedicated resources.

  two or three times, and a successful run has zero of those lines. So the
  outcome is decidable from the log *before* router2 starts, which makes a sweep
  cheap to cut short. A run is ~3 s; `seq 24 400 | xargs -P 4` covers the space
  in about five minutes.

  1-in-377 is not a seed to hunt, it is a wall: the global clock router cannot
  reliably reach that slice region from `BUFGCTRL_X0Y16` at this design size.
  Expect the next thing added to the AXI clock domain to fail outright at every
  seed. **This is now the most valuable place to spend effort upstream** — ahead
  of `-nocarry`, because `-nocarry` costs performance while this costs the
  ability to build at all.
- **No timing model worth the name.** `--freq 100` is nominal. "It routed" does
  not mean "it meets timing", which matters more as the DSP grows.

**Characterised and supported — just unused by us so far:**

- `DSP48E1`: 436 segbits plus a dedicated `pack_dsp_xc7.cc`. Now wrapped and
  build-verified; see the tiers above.
- `MMCME2`/`PLLE2`: CMT segbits present, emitted by `fasm.cc` — 378 and 343
  features respectively, and every feature `fasm.cc` writes is in the database.
  The two the zynq7 database lacks relative to artix7 both encode external
  feedback compensation, which `fasm.cc` rejects outright and which the `_BASE`
  variants have no parameter for. Note that this fork carries hardware-verified
  MMCM corrections not upstream, and a comment recording that hardcoded
  loop-filter and lock tables once produced a PLL too jittery for synchronous
  logic — they are now derived from `CLKFBOUT_MULT`, so pass it.
- Block RAM: proven working this session (`RAMB18E1`, true dual-port, two clocks).
- `ODDR`/`OSERDES`: every feature nextpnr emits is in the database.

**Our own gap — now closed.** The EHDL stdlib had wrappers for only `BUFG`,
`IBUFDS`, `IDDR`, `OBUF` and `PS7`, which is why the earlier "verified working:
OBUFDS, ODDR" claim could not have been true: those primitives had never been
instantiated from EHDL at all. Added since: `Hw.Xilinx.DSP48E1`,
`Hw.Xilinx.MMCME2_BASE`, `Hw.Xilinx.PLLE2_BASE`, `Hw.Xilinx.ODDR`,
`Hw.Xilinx.OBUFDS`. Tests in `test/xilinx_primitives_test.exs` assert on emitted
Verilog, because the simulator drives every blackbox port to 0 and so cannot
check a primitive's behaviour at all — the only thing that can be wrong at this
layer is the instantiation text.

Three toolchain traps are documented in those moduledocs rather than passed
through as parameters, on the principle that a parameter which is accepted and
discarded is worse than one that does not exist:

- **`DSP48E1`**: `USE_MULT`, `SEL_PATTERN` and `USE_PATTERN_DETECT` have zero
  features in the prjxray database and `write_dsp_cell` never reads them. `MASK`
  is truncated to 46 bits by a `fasm.cc` comment claiming prjxray recognises only
  46 — which is **wrong for zynq7**, where `MASK[46]` and `MASK[47]` both exist.
  Visible in the `prim_check` FASM as `MASK[45:0]`. None of these is exposed, and
  `PATTERNDETECT`/`PATTERNBDETECT`/`OVERFLOW`/`UNDERFLOW` must not be relied on.
- **`ODDR` tristate is silently unconfigured.** nextpnr creates an
  `OLOGICE3_TFF` when `Q` drives the `T` of an `OBUFT`/`OBUFTDS`, but `write_io`
  does not list that type among the ones it dispatches to `write_iol_config`. It
  is skipped, not rejected: **zero OLOGIC bits, clean build.** The database has
  full TFF coverage, so this is a missing branch in nextpnr, not a prjxray gap —
  probably because `TQUSED` is the one TFF feature the database lacks. Same class
  as `DIFF_TERM`, different tool. The data path is fine.
- **`OBUFDS` is not a differential buffer**, it is two anti-phase single-ended
  drivers plus `OUT_DIFF` and `LVDS_25.OUT` — nextpnr says `// FIXME: true diff
  outputs`. Only `LVDS_25` and `TMDS_33` have encodable differential-output
  features on this part, and anything else falls through to the single-ended
  `DRIVE`/`SLEW` chain silently. So `IOSTANDARD` is hardcoded, not a parameter.

**The meta-gap:** prjxray's fuzzers require Vivado, so fixing the ILOGIC and
termination gaps *by their method* needs the vendor tool. The hardware-oracle
approach in `_fuzz/` is the vendor-free alternative and is built and validated
(224/224 on the bit mapping); it just needs an oracle, which now exists.

## Known-unfixed

- `Hw.PS7` declares `maxigp0_awsize`/`arsize` as 3 bits; should be 2.
- `priv/xilinx/ps7_blackbox.v` is redundant; yosys ships PS7 in `cells_xtra.v`.
- `Hw.Sim.Eval` and `Hw.Sim.Compiler` disagree on `ReverseBits` and `Popcount` —
  the interpreter is correct, the compiler approximates.
- Nerves artifact checksums do not cover DTS edits (see the nervezynq notes).
