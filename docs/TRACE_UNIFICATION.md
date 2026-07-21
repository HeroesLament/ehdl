# Unified Trace Architecture — Design Doc

**Status:** Draft for review · **Date:** 2026-07-19 · **Scope:** simulation / waveform / testability subsystem

## 1. Motivation

The project has **two waveform subsystems that grew from opposite ends of the simulator** and do not share code, concepts, or reach:

| | `Hw.Simtrace` (`lib/hw/simtrace.ex`) | `Hw.Waveform` (`lib/hw/waveform.ex`) |
|---|---|---|
| Data source | Live GenServer engine, via `:sys.install` watchers into ElixirScope TraceDB | NIF backend change log (`Hw.Sim.Backend.step/3`) |
| Sees | Entity **register** state (`sie_`, `cdc_`, `phy_` internals) | Top-level **ports/signals** (`:led`, `:wifi_txd`) |
| Query verbs | Rich: `at`, `timeline`, `find_when`, `diff`, `transitions`, `snapshot`, `context` | Assertion-only: `assert_stable`, `assert_sequence`, `assert_reaches` |
| Rendering | ASCII (its own renderer, `simtrace/waveform.ex`) | ASCII (a near-twin renderer) + VCD export (`to_vcd/2`) + DSView/sigrok |
| Attaches to | `Hw.Sim` (Elixir engine) only | `Hw.Sim.Backend` (NIF) only |

The two answer the **same conceptual question** — "what was signal X doing over time?" — but a user must know which engine their signal lives on to pick the right tool, cannot `find_when` on a top-level port, cannot assert on an entity register, and maintains two near-identical ASCII renderers that can drift.

This split is not a design decision. It is an artifact of `Hw.Simtrace` being born on the Elixir engine and `Hw.Waveform` on the NIF engine. **This doc proposes collapsing both onto one hierarchical `Trace` value type**, engine-agnostic, with a single query layer and single renderer stack above it.

## 2. The unifying insight — one canonical change stream

Both engines already emit the **same primitive**: an ordered stream of change records.

- NIF backend: `step/3` returns `[{time_ps, signal_atom, old_val, new_val}]` — contract declared at `lib/hw/sim/backend.ex:94-96`, returned at `backend.ex:301-306`, consumed by `Hw.Waveform.record/2` at `waveform.ex:225`.
- Elixir engine: the `Clock` process broadcasts `{:commit, time_ps}` and entities expose `reg_state`; `Hw.Simtrace`'s watchers already reconstruct per-time snapshots from this (`lib/hw/simtrace/attach.ex:138-149`).

**That `{time_ps, signal, old, new}` record is the natural seam.** If a single `Trace` type ingests this stream from *either* engine, then everything above it (queries, renderers, exporters) becomes agnostic to which engine produced the data, and everything below it (the two engines) needs only a thin adapter.

## 3. Design decision: hierarchical scope (not flat)

**Decision: signals are addressed hierarchically as `scope-path + leaf`, not by a flat name.** This follows established prior art from both directions:

- **Hardcaml** (the OCaml framework closest to this architecture) names signals hierarchically with `$` as the path separator (`Scope.name`). Its waveform viewer uses that hierarchy to render a **tree view** automatically (`auto_label_hierarchical_ports`, port prefixes `i$`/`o$`). Scope is load-bearing for navigability, not cosmetic. ([Hardcaml Scope docs](https://zprize.hardcaml.com/odoc/hardcaml/Hardcaml/Scope/index.html), [Jane Street: ASCII waveforms for testing](https://blog.janestreet.com/using-ascii-waveforms-to-test-hardware-designs/))
- **VCD** — the format `to_vcd/2` already emits for GTKWave/Surfer — is natively hierarchical: `$scope module top $end … $upscope $end`, every `$var` nested inside a scope. GTKWave renders that tree in its signal browser. A flat namespace *discards* structure the export format wants back. ([VCD format — Wikipedia](https://en.wikipedia.org/wiki/Value_change_dump), [File format:vcd — sigrok](https://sigrok.org/wiki/File_format:Vcd))

Critically, **the hierarchy already exists latently** in this codebase. `Hw.Sim.Schedule` partitions ops into entities by signal-name *prefix* (`@instance_prefixes`, `lib/hw/sim/schedule.ex:153-163`): `sie_`, `cdc_`, `phy_`, `_top_`. That prefix convention *is* a scope tree hiding inside flat names. Unification is largely making it explicit:

```
sie_rx_state   →   sie.rx_state
cdc_dev_state  →   cdc.dev_state
:led           →   top.led
:wifi_txd      →   top.wifi_txd
```

This also dissolves the naming-collision concern: `sie.rx_state` and `top.led` cannot collide because the scope path disambiguates — precisely why the industry chose hierarchy over flat-name-with-prefixes.

## 4. Target architecture

```
        ┌──────────────────────────────────────────────────────┐
        │  Query layer  (engine-agnostic, operates on Trace)    │
        │  at · timeline · find_when · first · transitions ·    │
        │  diff · snapshot · context · slice · values           │
        ├──────────────────────────────────────────────────────┤
        │  Assertion layer  (ExUnit macros over Trace)          │
        │  assert_stable · assert_sequence · assert_reaches ·   │
        │  assert_at · assert_waveform                          │
        ├──────────────────────────────────────────────────────┤
        │  Render layer  (single hierarchical renderer)         │
        │  ascii/2 · to_vcd/2 · to_dsl · to_sr                  │
        └──────────────────────────────────────────────────────┘
                              ▲
                    ┌─────────┴─────────┐
                    │   Hw.Trace  (value type)                  │
                    │   • signals: %{path => %{width, hint}}    │
                    │   • changes: ordered [{ps, path, o, n}]   │
                    │   • scope tree (derived)                  │
                    └─────────┬─────────┘
                    ┌─────────┴──────────┐
          ┌─────────▼────────┐  ┌────────▼─────────┐
          │ NIF adapter      │  │ Live adapter     │
          │ from step/3 log  │  │ from :sys watcher│
          │ (backend.ex)     │  │ stream (attach)  │
          └──────────────────┘  └──────────────────┘
```

### 4.1 `Hw.Trace` — the value type

An immutable struct:

- `signals`: `%{path => %{width: integer, hint: :bit | :hex | :unsigned | :signed | {:enum, map}, sense: :high | :low}}` where `path` is a scope-qualified identifier (dotted atom `:"sie.rx_state"`, or a `{[:sie], :rx_state}` tuple — see §7 Q1).
- `changes`: ordered `[{time_ps, path, old, new}]` — the canonical stream, identical shape to today's `backend.ex:88`.
- `scope_tree`: derived index `%{scope_path => [child_scope | leaf]}` for tree rendering and scope-filtered queries.
- `time_unit` / `clock_meta`: ps-per-tick per clock, migrated from `Hw.Simtrace.ps_per_tick/2` (`simtrace.ex:230`).

`Hw.Trace` owns **no** engine knowledge — it is pure data plus pure functions.

### 4.2 Adapters (the only engine-aware code)

- **`Hw.Trace.Adapter.Nif`** — folds a `step/3` change log into a `Trace`. Trivial: the shapes already match; it adds scope resolution (prefix → scope path) and signal metadata from the schedule's `signal_widths`.
- **`Hw.Trace.Adapter.Live`** — subsumes today's `Hw.Simtrace.Attach`. Keeps the non-invasive `:sys.install` watcher mechanism (`attach.ex:84-154`) but writes into a `Trace` (or streams records that fold into one) instead of a bespoke ElixirScope schema. ElixirScope becomes an *implementation detail of this adapter*, not a hard dependency of the whole query layer (removing the `query.ex:190` / `attach.ex:143` `apply/3` coupling).

### 4.3 Query layer

Port every `Hw.Simtrace` verb (`simtrace.ex:259-455`) to operate on `Trace`, with an **optional scope filter** instead of a mandatory `entity` atom:

```elixir
# today (entity-mandatory, live-only):
Hw.Simtrace.find_when(st, :sie, rx_state: 2)

# unified (scope-optional, engine-agnostic):
Hw.Trace.find_when(trace, "sie.rx_state": 2)        # cross-scope OK
Hw.Trace.find_when(trace, scope: :sie, rx_state: 2) # scoped
Hw.Trace.find_when(trace, "top.led": 0xFF)          # ← now works on a PORT
```

The last line is the headline capability win: `find_when`/`diff`/`transitions` gain visibility into top-level ports, which `Hw.Simtrace` never had.

### 4.4 Render layer — collapse the twins

`lib/hw/waveform.ex` and `lib/hw/simtrace/waveform.ex` contain near-identical `sample_to_columns` / `format_value` / 1-bit-glyph logic. **Merge into one `Hw.Trace.Render` that groups rows by scope** (generalizing the domain-grouping already in `waveform.ex`). VCD export (`waveform.ex:495`) becomes **lossless**: emit real `$scope`/`$upscope` nesting from `scope_tree` so GTKWave/Surfer show the design hierarchy — a direct win over today's flat VCD. Also fixes the no-op `type = if width==1, do: "wire", else: "wire"` at `waveform.ex:708` (make it `reg` vs `wire`).

### 4.5 Assertion layer

`Hw.Waveform.ExUnit` macros re-point at `Trace`. Because `Trace` is engine-agnostic, **the same assertions run against live-engine and NIF traces** — today's `fsm_waveform_test.exs` (NIF) and `hello_board_*` tests (Elixir engine) converge on one assertion API. Resolves the current duplication where both `Hw.Waveform.*` and `Hw.Waveform.ExUnit.*` define `assert_stable/assert_sequence/assert_reaches`; the value-module versions delegate or are removed.

## 5. What this fixes (traceability to known issues)

- Two ASCII renderers that can drift → one renderer.
- `find_when`/`diff`/`transitions` blind to ports → uniform signal space.
- Assertions blind to entity internals → same.
- Duplicated assertion APIs (`Hw.Waveform` vs `Hw.Waveform.ExUnit`) → one.
- Flat/lossy VCD export → hierarchical, GTKWave-navigable.
- ElixirScope as a hard dep of the query path → confined to the Live adapter.
- No-op VCD `type` conditional (`waveform.ex:708`) → corrected.
- Mislabeled `export_sr/3` (`simtrace.ex:206` writes a `.dsl`, not `.sr`) → real exporters keyed off `Trace`.
- USB-specific hardcoded port prefix list in `select_signals(:ports)` (`waveform.ex:519`) → replaced by scope-tree selection.

## 6. Migration plan (Trace-seam-first, both old paths stay green)

Sequenced to keep the suite passing at every step. **No rename in this effort** — the tree stays under `Hw`; the eventual `Hw → EHDL/ElixirHDL` rename is a separate mechanical pass done *once* on the unified tree (see §8).

1. **Define `Hw.Trace`** (struct + scope resolution from the prefix table at `schedule.ex:153`) and `Hw.Trace.Render.ascii/2`. Pure, no engine calls. Unit-test the renderer against fixture change logs.
2. **`Hw.Trace.Adapter.Nif`** — fold a `step/3` log into a `Trace`. Add a characterization test: existing `fsm_waveform_test.exs` waveforms reproduced through `Trace`.
3. **Port query verbs** onto `Trace` (`at/timeline/find_when/first/transitions/diff/snapshot/context`). Keep `Hw.Simtrace` delegating to them so no caller breaks yet.
4. **`Hw.Trace.Adapter.Live`** — reimplement `attach` to feed a `Trace`; `Hw.Simtrace.*` becomes a thin compatibility shim over `Hw.Trace`.
5. **Re-point assertions** (`Hw.Waveform.ExUnit`) at `Trace`; converge the duplicated `assert_*`.
6. **Lossless hierarchical VCD/DSL/SR exporters** off `Trace`; fix `export_sr`, the VCD `type` no-op, and drop the USB-prefix port heuristic.
7. **Deprecate shims** (`Hw.Simtrace` compat layer, value-module assertion duplicates) once callers migrate.
8. **(Separate effort) Rename** `Hw → <new namespace>` across the unified tree, incl. app atom `:hw` (`mix.exs:6`), NIF `otp_app: :hw` (`nif.ex:25`), and `:application.get_key(:hw, …)` (`analysis.ex:113`).

Each step is independently shippable and leaves `mix test` green.

## 6a. Blast-radius notes (from module inventory)

- **No test drives `Hw.Simtrace`** — it is IEx-only. Steps 3–4 (query verbs, Live adapter) have *zero* test impact. The only external caller is `scripts/export_usb_enum.exs:14`.
- **The entire NIF-backend + `Hw.Waveform` path is one test file** — `test/fsm_waveform_test.exs`. It is the whole safety net for steps 1–2 and 5's NIF side.
- **Assertion re-point (step 5) touches exactly 4 files** that `import Hw.Waveform.ExUnit`: `fsm_waveform_test.exs` (NIF-fed), `hello_board_cdc_test.exs`, `hello_board_uart_tx_test.exs`, `phy_debug_test.exs` (GenServer-fed via `record_snapshot`).
- **Three prefix tables, not one.** The scope resolver must read the *canonical* `@instance_prefixes` (`schedule.ex:153`) **and** honor `@cdc_owned_signals` (`schedule.ex:290`), which routes `sie_ep_in_*` and `dev_addr` into scope `:cdc` — else `dev_addr`'s scope is wrong. The divergent `known_prefixes` (`waveform.ex:520`, adds `axi_`/`spi_`, drops `pll_`/`prog_`/`diag_`) is drift to delete, not a second source of truth.
- **The 7 waveform-free GenServer tests** (`hello_board_phy/uart_rx/loopback/reset`, `hdl_case`, `defhw`, `phy_schedule_check`) are immune to the Trace/renderer merge, but every one calls `force_reg(sim, :entity, …)` — so they are the regression surface for any change to `@instance_prefixes` entity *routing* (relevant only if §7 Q2's IR-derived scope lands), not for the waveform work.

## 6b. Implementation status (live)

Milestones landed and green (`mix test`):

- **M1** — `Hw.Trace`, `Hw.Trace.Scope`, `Hw.Trace.Render` (`lib/hw/trace/{core,scope,render}.ex`). Struct, two fold functions (`apply_delta`/`apply_snapshot`), scope resolver honoring the `@cdc_owned_signals` override, merged renderer. 12 unit tests.
- **M2** — `Hw.Trace.Adapter.Nif` (`lib/hw/trace/adapter/nif.ex`). Characterization test (`test/trace_nif_characterization_test.exs`) proves a `Trace` reproduces `Hw.Waveform`'s recorded values exactly over a full UART frame, on both sparse and dense paths.
- **M3** — `Hw.Trace.Query` (`lib/hw/trace/query.ex`). All verbs (`timeline/find_when/first/transitions/diff/snapshot`) with scope filter + index-or-time axis. 15 unit tests, including port queries (`find_when(trace, [], "top.led": 1)`) that Simtrace never supported.
- **M4 (partial)** — `Hw.Trace.Adapter.Live` (`lib/hw/trace/adapter/live.ex`) + `Hw.Simtrace.to_trace/1` bridge. `reg_state` keys are already fully-prefixed schedule names (`entity.ex:215`), so they fold straight through `apply_snapshot`. ElixirScope is now confined to this one adapter (`from_history/1`).
- **M5** — `Hw.Trace.ExUnit` (`lib/hw/trace/ex_unit.ex`): `assert_at/assert_stable/assert_sequence/assert_reaches/assert_waveform/print_waveform` over `Hw.Trace`, engine-agnostic. 6 unit tests. **Fixed the `assert_stable` cycle-numbering bug** (§1 of the original review): failures now report the *absolute* cycle, correct for non-zero windows, with a regression test on window `3..6`. `Hw.Waveform.ExUnit` remains as the legacy `%Waveform{}`-only surface; `Hw.Trace.ExUnit` is canonical going forward. (The `assert_*` "duplication" between `Hw.Waveform` and `Hw.Waveform.ExUnit` was in fact delegation, not copies; the real triplication is `format_value`, addressed in M6 rendering.)
- **M6** — `Hw.Trace.VCD` (`lib/hw/trace/vcd.ex`): hierarchical VCD export emitting real nested `$scope`/`$upscope` blocks from the scope tree (GTKWave/Surfer show the design tree), plus the **reg-vs-wire `$var` type fix** for the old no-op `type = if width==1, do: "wire", else: "wire"` conditional. 5 unit tests.

**Full suite: 158 passing.** The unified `Hw.Trace` now ingests from both engines (NIF + live), with one query layer, one renderer, one assertion API, and hierarchical VCD export above it.

### Remaining follow-ups (not blocking)
- Simtrace verb rewire (M4 scaffold, §6b) — needs the live integration test first.
- Retire `Hw.Waveform`'s flat `to_vcd` / the mislabeled `export_sr` (`simtrace.ex:206`) in favor of the `Trace` exporters, once callers migrate.
- The `Hw → EHDL`/`ElixirHDL` rename (deferred, mechanical, done once on the unified tree).

### M4 remaining: the Simtrace verb rewire (scaffolded, not yet done)

The existing `Hw.Simtrace.{timeline,find_when,first,transitions,diff,snapshot}` still route through the TraceDB-backed `Hw.Simtrace.Query`. Rewiring them to delegate to `Hw.Trace.Query` over a `to_trace/1`-materialized trace is deferred deliberately: **no test exercises the live Simtrace path**, so a blind rewire would change an unverified behavior.

Prerequisite (do first): a **live integration test** — boot a real sim (e.g. `HelloBoard.Top` or a small FSM on the GenServer engine), `Hw.Simtrace.attach`, tick, and assert on the entity-scoped verbs. This gives CI coverage of the current contract.

Shape-compatibility to preserve when rewiring:
- Simtrace `timeline/3` returns `[%{time_ps, state}]` where `state` is an entity-scoped **leaf** map. `Hw.Trace.Query.timeline(trace, scope: e)` returns `[%{index, time_ps, state}]` with the same leaf keys — compatible if the extra `:index` key is acceptable and the entity atom maps to a scope atom (they're equal: `:sie` ↔ `:sie`).
- `find_when/3`, `transitions/3`, `diff/4`, `first/3`, `snapshot/2` map 1:1 onto the `Hw.Trace.Query` equivalents with `scope: entity`.
- `at/3`, `get/4` (single-register point reads) map to `Trace.at/3` + address resolution.

Rewire steps once the integration test is green:
1. Add `to_trace/1` caching (materializing per-call is O(history); memoize on the struct or accept the cost for IEx use).
2. Reimplement each `Hw.Simtrace` verb as a thin wrapper: `to_trace(st)` → `Hw.Trace.Query.<verb>(trace, [scope: entity], ...)`.
3. Delete `Hw.Simtrace.Query` (TraceDB walker) and the `apply/3` ElixirScope calls in it; ElixirScope now lives only in `Adapter.Live`.
4. Run the integration test + full suite.

## 7. Open questions for review

1. **Path representation:** dotted atom (`:"sie.rx_state"`) vs. tuple (`{[:sie], :rx_state}`) vs. string. Atoms are ergonomic at the IEx prompt and match today's signal atoms; tuples are cleaner for programmatic scope filtering. Recommendation: **tuple internally, dotted-atom/string accepted at the API boundary** for prompt ergonomics.
2. **Scope source of truth:** derive scope from the existing prefix table (`schedule.ex:153`) now, or thread real instance metadata from elaboration through the IR? The prefix table is USB/UART-specific and the schedule comment (`schedule.ex:146-149`) already flags it should be IR-derived. Recommendation: **prefix table now, IR-derived scope as a fast follow** — it also unblocks non-USB protocols (I2C/SPI/CAN/SWD).
3. **Live vs. NIF semantics parity:** the Elixir engine commits per-entity with an explicit cross-settle; the NIF emits a flat per-edge log. Do we guarantee *identical* `Trace` output from both for the same design, or document acceptable ordering differences within a timestamp?
4. **ElixirScope:** keep it as the Live adapter's storage backend, or move to a plain ETS/term store now that the query layer no longer depends on it?

## 8. Non-goals

- The `Hw → EHDL`/`ElixirHDL` rename (deferred; mechanical; done once on the unified tree).
- New protocol host models (I2C/SPI/CAN/SWD) — but §7 Q2's IR-derived scope is the enabler for them.
- Closed-loop USB enumeration assertion — orthogonal; benefits from unified assertions but is its own task.

## Appendix — reference index

- Backend change-record contract: `lib/hw/sim/backend.ex:94-96` (callback), `:301-306` (return), consumed `lib/hw/waveform.ex:225`
- `Hw.Waveform.ExUnit` module: `lib/hw/waveform/ex_unit.ex` (imports at `fsm_waveform_test.exs:4`, `hello_board_cdc_test.exs:4`, `hello_board_uart_tx_test.exs:5`, `phy_debug_test.exs:4`)
- Second, divergent prefix list: `lib/hw/waveform.ex:520` (`known_prefixes`, adds `axi_`/`spi_`, drops `pll_`/`prog_`/`diag_`); `@cdc_owned_signals` at `schedule.ex:290`
- Live watcher mechanism: `lib/hw/simtrace/attach.ex:84-154`, snapshot at `:138-149`; ElixirScope coupling `attach.ex:143`, `query.ex:190`
- Simtrace query verbs: `lib/hw/simtrace.ex:259-455`
- Entity prefix table (latent scope tree): `lib/hw/sim/schedule.ex:153-163`; "should be IR-derived" note `:146-149`
- Two ASCII renderers: `lib/hw/waveform.ex` and `lib/hw/simtrace/waveform.ex`
- VCD export + no-op `type`: `lib/hw/waveform.ex:495`, `:708`
- USB-prefix port heuristic: `lib/hw/waveform.ex:519`
- Mislabeled SR export: `lib/hw/simtrace.ex:206`
- Rename touchpoints: `mix.exs:6`, `lib/hw/sim/nif.ex:25`, `lib/hw/analysis.ex:113`
