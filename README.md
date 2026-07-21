# EHDL

**Elixir HDL** — a hardware description language embedded in Elixir. You write
synchronous digital hardware as ordinary Elixir modules; EHDL elaborates them
into an intermediate representation, emits synthesizable Verilog, and runs the
same designs in a fast native simulator so you can test them with ExUnit.

EHDL is a research/hobby toolchain built around a small, honest core: two
behavioral primitives (`comb` and `on`) that map directly to how real silicon
works, plus a component/interface system for composing them into larger designs.
The reference design is a USB 2.0 Full-Speed → ESP32 serial bridge (CDC-ACM)
targeting the Lattice ECP5 on a ULX3S board.

> Status: pre-release, under active development. The DSL, elaborator, Verilog
> backend, and simulator are working; the USB stack enumerates in simulation.
> APIs may still change.

## Why another HDL

Verilog and VHDL make you carry the whole language in your head to describe
what is, at bottom, a small set of ideas: registers that update on a clock edge,
combinational logic that settles continuously, and structural composition of the
two. EHDL takes those ideas as its primitives and borrows Elixir's macro system
for everything else — so a component is a plain module, parameterization is just
compile-time values, replication is a comprehension, and your testbench is
ExUnit. The payoff is that the same source is analyzable (a linter with real
hardware rules), simulatable (native-speed, scriptable from IEx), and
synthesizable (Verilog out).

## The mental model

Two primitives carry the whole language, and they mean different things by `=`:

- **`comb do … end`** — combinational logic. A *standing waterfall*: every
  assignment describes a wire that is *continuously* equal to its right-hand
  side, all the time, with no clock involved. `=` means "is permanently wired
  to." Order is (almost) irrelevant; feeding a `comb` result back into its own
  input with no register in the loop is a real bug (and EHDL's analyzer flags
  it).

- **`on :clk do … end`** — clocked (sequential) logic. On each rising edge,
  *every* right-hand side is read from the old state simultaneously, then every
  left-hand side is written simultaneously. `=` means "on the next edge,
  becomes." This is the only primitive that creates flip-flops. A register that
  isn't written on an edge simply *holds* — and "holding" is itself an active
  decision the logic makes every cycle.

Everything else — finite state machines, reusable logic templates, replicated
lanes — is sugar that lowers into those two. A `wire` is neutral: whether it
becomes a flip-flop or a bare wire is decided by whether an `on` block drives
it, not by its declaration.

## A minimal component

```elixir
defmodule Counter do
  use Hw.Component

  clock  :clk
  input  :rst,   1
  input  :en,    1
  output :count, 8

  on :clk do
    if rst do
      count = 0
    else
      if en do
        count = count + 1
      end
    end
  end
end

# Elaborate to IR and emit Verilog
design  = Hw.Compile.Elaborate.elaborate(Counter)
verilog = Hw.emit(design)
```

A slightly richer component — an 8N1 UART transmitter — shows the FSM sugar,
combinational outputs, and reusable logic fragments (`defhw`) working together:

```elixir
defmodule Hw.UART.TX do
  use Hw.Component

  param :CLK_FREQ,  default: 48_000_000
  param :BAUD_RATE, default: 115_200

  clock  :clk, freq: 48.0
  input  :rst,   1
  input  :data,  8
  input  :valid, 1
  output :ready, 1
  output :txd,   1

  wire :shift_reg, 10, init: 0b1111111111
  wire :tick,       1

  comb do
    tick = (baud_cnt == CLK_FREQ / BAUD_RATE - 1)
    txd  = shift_reg[0..0]              # txd IS the LSB of the shift register
  end

  fsm :tx_state, clock: :clk, reset: :rst, init: :idle do
    defaults do
      ready = 1
    end

    case tx_state do
      :idle ->
        on valid do
          load_frame(data)
          next :sending
        end

      :sending ->
        ready = 0
        on tick do
          shift_bit()
          on bit_cnt == 9, next: :idle
        end
    end
  end
end
```

## The DSL vocabulary

**Declarations** (the nouns — inert structure):
`param`, `clock` (with domain + `reset_style: :sync | :async | :none`),
`input` / `output` / `inout`, `wire`, `memory`, `complex`, `blackbox`,
`tristate`, and interface-role bindings `provides` / `consumes`.

**Logic blocks** (the verbs — behavior):
`comb` and `on` (the two atoms); `fsm` (state machines, `:binary` / `:onehot`
/ `:gray` encodings); `defhw` (inlinable logic templates — expression-level or
statement-level, or simulation-only when they contain `on` blocks); `generate`
(compile-time replication over a range); `hdl_case` (a `case` variant that
accepts `<<signal::width>>` binary patterns); and structural composition via
`instance`, `interface`, and `connect`.

## Standard component library

Under `lib/hw/std/`:

- **Clocking / reset:** `ResetSync` (two-flop synchronizer with hold counter),
  `CDC.Sync2`, `CDC.PulseSync`.
- **Interfaces / buffers:** `FIFO`, `AXI4Master`, `AXI4Slave`, `LVDS25`.
- **Serial:** `UART.TX`, `UART.RX`, `ESP32ProgCtrl`.
- **USB Full-Speed stack:** `USB.FSPhy` (NRZI, bit-stuffing, EOP),
  `USB.SIE` (packet FSM, PID decode, CRC5/CRC16, endpoint buffers),
  `USB.CDCSerial` (enumeration, descriptor ROM, EP0 control, EP1 bulk bridge),
  plus `USB.CRC5`, `USB.CRC16`, `USB.ClockTrim`.
- **DSP:** `CORDIC`.

The reference top-level design lives at `designs/hello_board/top.ex`
(`HelloBoard.Top`) and wires the USB stack to a UART/ESP32 bridge for the ULX3S.

## Installation

Requires **Elixir 1.20+ / Erlang 29+** and a **Rust toolchain** (the simulator
core is a Rustler NIF, built automatically on first compile).

```bash
git clone https://github.com/HeroesLament/ehdl.git
cd ehdl
mix deps.get
mix compile          # also builds the native simulator NIF
mix test
```

## Usage

**Simulate and test.** Designs run in a native simulator driven from Elixir, so
testbenches are ordinary ExUnit tests — drive inputs, tick the clock, assert on
signals. See `test/` for the HelloBoard UART, PHY, CDC, and loopback benches,
and the trace/query helpers for waveform-style assertions.

**Analyze.** `mix hw.check` runs a hardware-aware linter over all compiled
components and exits non-zero on errors (CI-friendly):

```bash
mix hw.check
mix hw.check --modules Hw.USB.SIE,Hw.USB.CDCSerial
mix hw.check --warnings-as-errors
```

Rules include combinational-loop detection, clock-domain-crossing checks,
multiple-driver / undriven-output / unconnected-input analysis, latch inference,
reset coverage, signal-width and endianness mismatches, and more (see
`lib/hw/analysis/rules/`).

**Emit Verilog.** Elaborate a component and call `Hw.emit/1` to get
synthesizable Verilog for your toolchain (e.g. Yosys + nextpnr-ecp5 for the
ULX3S).

**Diagram.** `mix hw.diagram` renders a component's wiring as Typst/SVG/PDF,
Graphviz DOT, or Mermaid:

```bash
mix hw.diagram HelloBoard.Top --format svg --output diagram.svg
mix hw.diagram HelloBoard.Top --format mermaid
```

**Snapshot.** `mix hw.snapshot` writes a filtered source tarball
(`~/ehdl_snapshot_*.tar.gz`), excluding build artifacts.

## Project layout

```
lib/hw/
  dsl/            # the component DSL: declarations, logic blocks, parser
  ir/             # intermediate representation: ops, types, signals
  compile/        # elaboration (DSL → IR), validation
  emit/           # Verilog backend
  sim/            # native (Rustler) simulator, scheduler, testbench harness
  std/            # standard component library (see above)
  analysis/       # hardware-aware linter and its rules
  trace/, simtrace/, waveform/   # tracing and waveform tooling
  boards/         # board support (ULX3S: PLL, pin constraints)
native/hw_sim_nif/  # Rust simulation core
designs/            # concrete designs (hello_board)
docs/               # USB theory notes, hdl_case reference, design findings
```

## Naming note

The public module namespace is `Hw.*` (e.g. `Hw.Component`, `Hw.USB.SIE`); the
OTP application and package are named `ehdl`. "EHDL" is the project/brand name;
`Hw` remains the code namespace.

## License

Dual-licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. Unless you explicitly state otherwise, any contribution you
submit for inclusion shall be dual-licensed as above, without additional terms.
