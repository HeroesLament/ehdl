# Trace Windows — Transaction Spans for `Hw.Trace`

**Status:** Draft for review · **Date:** 2026-07-19 · **Depends on:** the unified `Hw.Trace` subsystem (`docs/TRACE_UNIFICATION.md`)

## 1. The problem

A realistic simulation trace is enormous — a full USB enumeration produced **2,739,854 change events**. But the *meaning* lives in a handful of narrow intervals that correspond to protocol phases: the SETUP packet, the ACK, the SET_ADDRESS transaction. Today a trace can only be sliced by raw index or picosecond (`{:index, n}`, `{:time, ps}`), which requires you to already know *when* the interesting thing happened. You want to name a region by *what it is* — "the SET_ADDRESS transaction" — not *when it is*.

This doc specifies a **window** (a named, possibly-nested time span) as a first-class part of `Hw.Trace`, and a `window:` option on every query/render/assert verb.

## 2. Prior art — the discipline already settled this

Two established mechanisms, at two layers:

- **GTKWave named markers** — *point-in-time* markers: 26 lettered markers A–Z for "points of interest," plus droppable named markers you navigate between, plus a typed `From`/`To` visible window. A *window* is the interval between two point markers. ([GTKWave main window](https://gtkwave.github.io/gtkwave/ui/mainwindow.html))
- **UVM transaction recording — `accept_tr`/`begin_tr`/`end_tr`** — the *producer* (a driver) brackets its own work as it executes: `begin_tr` / `end_tr` stamp `begin_time` / `end_time` and record a **transaction that has a start and end time representing when it was active**. Multi-phase protocols mark sub-phases, and `begin_child_tr`/`end_child_tr` model **parent/child nesting** — a SETUP transaction contains its token/data/handshake sub-phases. ([UVM transaction](https://verificationacademy.com/verification-methodology-reference/uvm/docs_1.1a/html/files/base/uvm_transaction-svh.html), [Improving UVM Transaction Recording](https://semiiphub.com/pulse/technical-articles/systemverilog-uvm-transaction-recording-modeling))

**The discipline's center of gravity is the producer-declared, nestable transaction span.** The viewer's point-markers are the degenerate zero-width case of the same idea. That is exactly the model below.

## 3. The type model

A single **`Hw.Trace.Window`** value — a transaction span:

```elixir
defmodule Hw.Trace.Window do
  @type t :: %__MODULE__{
    label:     atom() | String.t(),      # :setup_get_descriptor, :set_address
    from:      non_neg_integer(),        # begin (in `axis` units)
    to:        non_neg_integer() | nil,  # end; nil = still open, or a point marker
    axis:      :index | :time,           # which trace axis the bounds are in
    parent:    reference() | nil,        # enclosing span (UVM begin_child_tr)
    id:        reference(),              # identity for nesting
    meta:      map()                     # arbitrary producer payload (PID, addr, bytes…)
  }
end
```

- A **point marker** (GTKWave A–Z) is the zero-width case: `to == from` (or `to == nil` for a bare mark).
- **Nesting** is by `parent`: `enumerate ⊃ set_address ⊃ {token, data, ack}`.
- `axis` reuses the index-vs-time abstraction already in `Hw.Trace.Query` (`@type point`), so windows are portable across engines.

`Hw.Trace` gains one field — a transactions timeline:

```elixir
# lib/hw/trace/core.ex — add to defstruct:
transactions: []   # [%Hw.Trace.Window{}], in begin order
```

Everything else about `Hw.Trace` is unchanged; windows ride alongside samples.

## 4. Three ways to make a window (one type, layered)

### Tier 1 — bounding events (works today, zero new sample infra)

A window is "from this transition to that one," built from `find_when`/`transitions` results you already have:

```elixir
[a] = find_when(trace, [scope: :sie], rx_state: 2)     # SETUP seen
[b] = find_when(trace, [scope: :cdc], dev_state: 1)    # addressed
w = Window.between(a, b, label: :set_address)
Window.around(event, :setup, pad: 500)                 # ±500 units around a point
```

This is the GTKWave "interval between two markers" pattern. It needs no producer changes and can ship first.

### Tier 2 — predicate extraction (fallback for un-instrumented signals)

A predicate over the trace yields *every maximal interval where it holds* — automatic segmentation:

```elixir
Window.where(trace, :bus_active, fn s -> s[{[:sie], :rx_state}] > 0 end)
# => [%Window{from: .., to: ..}, ...] one per active burst
```

This is `transitions` generalized from a single edge to interval extraction. Use it when the producer *didn't* mark something.

### Tier 3 — producer-declared spans (the UVM `begin_tr`/`end_tr` model — primary)

The driver brackets its own phases as it drives. `Hw.Trace` gets the recording API:

```elixir
trace = Trace.begin_tr(trace, :setup_get_descriptor, time)
  trace = Trace.begin_tr(trace, :token, time)   # nested (child)
  trace = Trace.end_tr(trace, :token, time)
  trace = Trace.begin_tr(trace, :data, time)
  trace = Trace.end_tr(trace, :data, time)
trace = Trace.end_tr(trace, :setup_get_descriptor, time)

Trace.mark(trace, :reset_deasserted, time)   # zero-width point marker
```

`USBHost.enumerate/1` is the natural first producer — it already has the phase boundaries as comments (`usb_host.ex:83` SETUP GET_DESCRIPTOR, `:109` SET_ADDRESS, `:145` SET_CONFIGURATION, and the `token_in`/`send_ack` sub-steps). Instrumenting it means each phase becomes a named, queryable, renderable span. **Every future protocol driver (I2C/SPI/CAN/SWD) does the same — this is the reusable segmentation machinery.**

## 5. The `window:` option (sugar over `from:`/`to:`)

Every query/render/assert verb gains a `window:` option that resolves a window to the `from:`/`to:` it already accepts:

```elixir
Render.ascii(trace, window: :set_address)                 # render only that phase
find_when(trace, [window: :in_data_stage], rx_pid: 0x2)   # query scoped to a phase
diff(trace, [window: :setup_get_descriptor], :first, :last)
assert_reaches(trace, "cdc.dev_state", 1, window: :set_address)
```

Resolution: `window:` looks up the named `%Window{}` in `trace.transactions`, converts its `axis`/`from`/`to` into the existing `point`/time-filter machinery (`Query.entry_at` + `filter_time`, `query.ex:185-192`). Nested windows resolve to their own span; the outer verb sees only the samples inside. No verb needs new *logic* — `window:` is a front-end that computes `from:`/`to:`.

## 6. Rendering & VCD

- **ASCII** (`Hw.Trace.Render`): a window adds a labeled band above the waveform (phase name spanning its columns), and `window:` narrows the rendered range. Nested windows indent.
- **VCD** (`Hw.Trace.VCD`): transaction spans map cleanly onto VCD's own hierarchy — but the natural target is GTKWave's named-marker feature (emit the span endpoints as named markers) so the phases show up in the viewer you already export to. Point markers → named markers directly.

## 7. Build plan (doc → review → code, milestones each green)

- **W1** — `Hw.Trace.Window` type + `trace.transactions` field + `begin_tr`/`end_tr`/`mark` recording API. Pure; unit-test span construction and nesting.
- **W2** — window resolution: `window:` option on `Query` verbs (`timeline`/`find_when`/`diff`/`snapshot`), resolving to existing `from:`/`to:`. Unit tests.
- **W3** — Tier 1 (`Window.between`/`around`) + Tier 2 (`Window.where` predicate extraction). Tests over a fixture trace.
- **W4** — `window:` on `Render.ascii` (labeled band + narrowed range) and assertion verbs.
- **W5** — instrument `USBHost.enumerate/1` with `begin_tr`/`end_tr` per phase (Tier 3). The payoff: `Render.ascii(utrace, window: :set_address)` on the real enumeration, and the ability to *assert* on a named phase.

Each milestone is independently shippable and leaves `mix test` green, mirroring the unification's sequencing.

## 7a. Resolved decisions (from review)

- **Nesting: overlap-allowed (UVM-style).** Spans are keyed by `id`; `begin_tr`/`end_tr` may interleave. `parent` is advisory (set to the innermost currently-open span at `begin_tr` time), not enforced. Handles concurrent phases (a timeout spanning a packet). Matches UVM's stream model.
- **Axis: store `time_ps`, resolve index lazily.** Grounded in prior art: GTKWave stores absolute time as truth and derives a separate index for acceleration ([GTKWave VCD internals](https://gtkwave.github.io/gtkwave/internals/vcd-recoding.html)); Hardcaml's waveterm is cycle-indexed only because it is purely cycle-based with no sub-cycle time ([Jane Street ASCII waveforms](https://blog.janestreet.com/using-ascii-waveforms-to-test-hardware-designs/)). Our traces carry real ps from the NIF kernel and will span multiple clocks, so time is the correct source of truth. Spans store `axis: :time` with ps bounds; `window:` converts ps→index at query time via the existing `Query.entry_at({:time, ps})` path. The producer (`USBHost`) only ever has sim time, never a sample index — this keeps it decoupled from trace internals.

## 8. Remaining open questions

1. **Axis for producer spans.** `begin_tr` gets a `time` — but the NIF change log's `time_ps` and the sample `index` diverge (a 2.7M-event enumeration has sparse-but-huge ps values). Record spans in `:time` (ps) and convert to index at query time, or record both? Recommendation: **store `:time`, resolve to index lazily** — ps is what the producer naturally has.
2. **Open/unclosed spans.** If `end_tr` is never called (crash, early exit), `to: nil` — render as "open to end of trace," or flag as an error? Recommendation: render open, warn in a lint pass.
3. **Overlap vs strict nesting.** UVM allows overlapping transactions on a stream, not just nesting. Do we enforce a stack discipline (`begin`/`end` must nest) or allow arbitrary overlap keyed by `id`? Recommendation: **allow overlap via `id`** (matches UVM), treat `parent` as advisory.
4. **Predicate windows on huge traces.** Tier 2 over 2.7M samples is O(n). Fine for a one-shot, but a `window:` that re-extracts each call is costly — memoize extracted windows on first use.

## Appendix — reference index

- `Hw.Trace` struct (add `transactions`): `lib/hw/trace/core.ex` (`defstruct`)
- Query point/axis machinery `window:` resolves to: `lib/hw/trace/query.ex:29` (`@type point`), `:185-192` (`entry_at`), `filter_time`
- Renderer to extend: `lib/hw/trace/render.ex` (`ascii/2`)
- First producer to instrument: `lib/hw/sim/usb_host.ex:58` (`enumerate/1`), phase boundaries at `:83`, `:102`, `:109`, `:145`; sub-steps `token_in/3` `:195`, `send_ack/1` `:203`
- Live finding motivating this: USB `sie_rx_state` transitions exactly once across 2.7M events (index 2,501,913 / ~13 µs), `dev_addr`/`dev_state` never leave 0 — the debug thread windows will make navigable.
