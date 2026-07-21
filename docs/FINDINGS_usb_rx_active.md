# Finding: RETRACTED — "PHY never asserts rx_active" was a tracing artifact

**Date:** 2026-07-19 · **Status:** RETRACTED — false alarm, tooling limitation
**Found via:** windowed `Hw.Trace` over `USBHost.enumerate_trace/2`

## What was claimed (and is WRONG)

An earlier version of this note claimed `fs_phy.ex:342` had a bug — that
`rx_active = (rx_state == 4)` never fired because the FSM used a stale state
number. **This conclusion was incorrect.** It was an artifact of how the trace
was built, not a fault in the PHY.

## What actually happened

The measurement that triggered the alarm was `phy_rx_active` reading a maximum
of 0 across the whole run. But direct query showed:

- `phy_rx_state` takes **every value 0..6, including 4** — 26,998 samples have
  `rx_state == 4`.
- At those exact samples, `rx_active` reads **0** — i.e. `{rx_state: 4,
  rx_active: 0}` simultaneously.

Since `rx_active` is *defined* as `(rx_state == 4)` (`fs_phy.ex:342`), reading 0
while `rx_state == 4` is **logically impossible** for a correctly observed
signal. The signal was not being observed — it was frozen at its init value.

## Root cause of the FALSE alarm (a real tooling gap)

`USBHost.enumerate_trace/2` folds the enumeration's **sparse change log** into
the trace via `Hw.Trace.apply_delta/3`. As documented in `TRACE_UNIFICATION.md`
and `backend.ex:216`, the sparse NIF change log carries only **registered**
signals that changed — **combinational** signals (like `rx_active`, `rx_valid`,
`rx_data`) never appear in the delta stream. So every comb signal in the trace
stayed pinned at its `init` value regardless of the real hardware.

`rx_state` looked correct because it is a **register** (emits deltas);
`rx_active` looked dead because it is **combinational** (emits nothing).

## Lessons

1. **The windows tooling worked** — navigation, phase scoping, and per-phase
   `diff` were all correct and fast. The bug was in what was *fed* to it.
2. **Combinational signals require the dense/snapshot fold**
   (`apply_snapshot`), not the sparse delta fold. `enumerate_trace` currently
   only offers the sparse path — this is a real gap to fix (add a `mode:
   :snapshot` option that steps + snapshots so comb signals are captured).
3. **Don't trust a flat comb signal as evidence of hardware behavior** when the
   trace was built from deltas. A max-0 comb reading means "not observed," not
   "never asserted." I over-concluded from it; corrected here.

## Resolution of the tooling gap (done)

`USBHost.enumerate_trace/2` now takes `mode: :snapshot`, which captures a dense
snapshot of the requested signals after each packet-level drive — so
combinational signals are recorded faithfully. Verified:

```
mode: :snapshot, signals: [:phy_rx_active, :phy_rx_valid, :phy_rx_state, :sie_rx_state]
  rx_active max: 1                       # was 0 (frozen) under :delta
  at rx_state==4: {928 samples, all {4, 1}}   # the impossibility is gone
```

This confirms the PHY `rx_active` logic is **correct** and the original alarm
was entirely a tracing artifact.

## Still open (legitimately) — now on trustworthy data

Enumeration does not complete (`dev_addr`/`cdc_dev_state` stay 0). With comb
signals now visible, the real lead is:

- `phy_rx_active` **max 1** — the PHY detects packets and enters active reception. ✓
- `phy_rx_valid` **max 0** — but it NEVER emits a decoded byte to the SIE.
- `sie_rx_state` **max 1** — consistent with a SIE that sees activity but never
  latches a valid byte.

So the receive path gets as far as "active" but `rx_valid` never fires.

### SECOND artifact caught — snapshot stride aliases with the bit period

Investigating `rx_valid`'s four conjuncts, `sample_en` read 0 at all 928
state-4 samples, and `sample_cnt` read **2 at all 1274 samples** — a constant,
which is impossible for a free-running counter. Cause: **snapshot mode takes one
sample per `drive` = one per bit = every `@clocks_per_bit` (4) cycles**, which
aliases exactly with the 4-cycle `sample_cnt`. The snapshot always lands on the
same sub-bit phase (`sample_cnt==2`) and never sees the 1-cycle `sample_en`
pulse.

Cycle-by-cycle capture (stepping 1 clock at a time) confirms the hardware is
correct:
```
{sample_cnt, sample_en} over 12 cycles:
  {1,0} {2,0} {3,0} {0,1} {1,0} {2,0} {3,0} {0,1} {1,0} {2,0} {3,0} {0,1}
```
`sample_en` pulses exactly when `sample_cnt==0`, every 4th cycle — as designed.

**Conclusion: there is NO bug in `rx_active` or `rx_valid`. Both alarms were
tracing artifacts** — the first from tracing a comb signal through the sparse
delta fold, the second from a snapshot stride that aliases with the bit period.

### The real tooling limitation

Bit-strided snapshots (per `drive`) cannot resolve sub-bit combinational signals
like `sample_en`/`rx_valid`. Observing them requires **per-cycle capture**. The
`mode: :snapshot` path needs a finer variant (snapshot every cycle over a bounded
window) before any conclusion about `rx_valid` firing *in-packet* can be drawn.

### RESOLVED with per-cycle capture — PHY is correct, bug is in the SIE

Added `stride: :cycle` to snapshot mode (snapshot every clock, not every bit).
On properly-sampled data:

```
sample_en max: 1     # fires (bit-strided sampling had aliased it to 0)
rx_valid  max: 1     # the PHY DOES emit valid decoded bytes
rx_active when rx_valid==1: always 1
cycles where rx_valid AND rx_active both 1: 112
```

**The PHY receive path is fully correct.** Both earlier "PHY bugs" were tracing
artifacts (sparse-fold blindness, then bit-stride aliasing).

The real, evidence-backed localization — all on **registered** signals (trustworthy,
no sampling caveat):

```
sie_rx_state distribution: %{0 => 624066, 1 => 55362}
```

- The SIE's `:idle → :recv_pid` trigger is `phy_rx_valid and phy_rx_active`
  (sie.ex:279). That condition holds on 112 cycles — so the SIE **does** get
  triggered.
- `sie_rx_state` spends 55,362 cycles in **state 1 (`:recv_pid`)** — it genuinely
  leaves idle and enters PID reception.
- But it **never advances past state 1.** It enters `:recv_pid` and stalls;
  never reaches `:recv_token` / `:recv_data`.

**Root-cause neighborhood: the `:recv_pid` state (sie.ex:284-303).** The SIE
begins receiving the PID but never completes a PID byte to transition onward
(`if bit_cnt == 7 do ... next :recv_token`). Either it isn't accumulating 8
`rx_valid` pulses within the PID field, or the bit-count/exit condition in
`:recv_pid` is wrong. Not yet fixed — to be investigated with per-cycle capture
of `sie_bit_cnt` / `byte_shift` across one `:recv_pid` episode, *carefully*
(three prior alarms in this file were premature; verify before asserting a fix).

## SIE prosecution — per-cycle recv_pid analysis (established facts)

Using `stride: :cycle` capture of the SIE internals, on **registered signals**
(trustworthy):

**Proven:**
- The SIE enters `:recv_pid` (state 1) — `sie_rx_state` dist `%{0 => 624066, 1 => 55362}`.
- `bit_cnt` **does** reach 7 in recv_pid — dist `%{0 =>1226,1=>448,...,7=>48902}`.
  It parks at 7 for 48,902 cycles. So PID bit-accumulation is NOT the bug.
- The exit condition (`rx_state==1 & bit_cnt==7 & rx_valid==1`) **IS reachable** —
  fires on **13 cycles**. So exit-unreachability is NOT the bug.
- On those 13 exit cycles, the PID decode routes correctly: **2 of 13 decode to
  `byte_shift=0b10000010` (b1=1,b2=0) → `route=:recv_token`** (a valid SETUP PID);
  the other 11 are stray single-bit garbage that correctly route to `:idle`. So
  PID *classification* is NOT broken either — it correctly identifies a token PID
  twice.

**Contradiction resolved + tool cleared:**
- Independent aggregate: `GLOBAL_MAX_rx_state` = 1 across all 679,428 samples —
  `sie_rx_state` genuinely NEVER reaches 2. Tool is trustworthy (clean, gapless
  per-cycle sequence; no straddled/dropped transitions).
- On the 2 cycles where the PID decodes to a token pattern, `sie_rx_state[i..i+3]`
  = `[1,1,1,1]` — the `next :recv_token` write **does not land**. The state stays 1.

**Sharpest suspect (HYPOTHESIS, not confirmed — old/new register value):**
`:recv_pid` reassigns `byte_shift` (sie.ex:286) and then branches on
`byte_shift[1..1]`/`byte_shift[2..2]` (sie.ex:291) *in the same clocked block*.
The branch likely reads a DIFFERENT `byte_shift` than the committed value the
trace captures — the classic old-vs-new register-timing trap. My offline route
calc used the captured (new) value and said `:recv_token`; the hardware may
branch on the pre-shift (old) value and fall through to `:idle`. This survives
human review because the code reads correctly at a glance.

**Old/new byte_shift hypothesis: TESTED and KILLED.** Captured `byte_shift` and
the committed `rx_pid` on all 13 decode cycles:
```
D bs=0x82 bs_bits12=10 rx_pid_next=0xC1   <- routes to recv_token, correctly, per the captured value
D bs=0x01 bs_bits12=00 rx_pid_next=0x80
D bs=0x04 bs_bits12=01 rx_pid_next=0x02
... (mostly single stray bits -> idle)
```
The hardware branch reads exactly the captured `byte_shift` (0x82 → bits[1..2]=10
→ recv_token). No old/new discrepancy. Classification and timing are both correct.

**VERIFIED FACT (the real bug, narrowed):** the SIE assembles an **invalid PID
byte**. On the two "good" cycles the committed `rx_pid` = **0xC1**, but a USB
SETUP token PID is **0x2D**. The device receives the packet but the assembled PID
byte is corrupt — so classification, even when it routes to recv_token, carries a
garbage PID, and mostly the assembled byte is junk that routes to :idle. Root
cause is in **PID byte assembly / bit ordering**, upstream of classification:
suspect the shift direction at sie.ex:286 `byte_shift = {phy_rx_data,
byte_shift[7..1]}`, the PHY's decoded-bit output order, or the rx_pid capture at
sie.ex:289.

**Do NOT assert which transform is wrong yet** — the 0x82/0xC1 vs 0x2D
relationship was NOT cleanly a bit-reversal on check (0x2D reversed = 0xB4, not
0x82), so the exact corruption is not yet characterized. Next session, fresh:
feed a KNOWN single PID (e.g. drive exactly 0x2D LSB-first) and capture
byte_shift bit-by-bit as it assembles, to see precisely how the received bit
stream maps to the assembled byte. Characterize the transform before touching
line 286.

## ROOT CAUSE — CONFIRMED (deterministic, three independent ways)

The SIE **drops the first PID bit**. Off-by-one at the `:idle → :recv_pid`
boundary.

**Proof 1 — input bit sequence:** the 8 bits the SIE consumed assembling the PID
were `1 0 0 0 0 0 1 1`; the host correctly sent `1 0 1 1 0 1 0 0` (0x2D LSB-first).
Corrupted from the very first bit.

**Proof 2 — alignment table:** the `phy_rx_valid` pulse that triggers the
idle→recv_pid transition (idx 624065) carries a valid data bit on `phy_rx_data`,
but the SIE changes state without latching it.

**Proof 3 — the source (sie.ex:278-287):**
```elixir
:idle ->
  on phy_rx_valid and phy_rx_active do
    bit_cnt  = 0
    next :recv_pid            # <-- transitions but DOES NOT shift the first bit
  end
:recv_pid ->
  on phy_rx_valid do
    byte_shift = {phy_rx_data, byte_shift[7..1]}   # the shift the idle arm is missing
    bit_cnt    = bit_cnt_next
```
The idle transition fires on a cycle where a valid bit is present, but only sets
`bit_cnt=0` and transitions — it never does the `byte_shift = {phy_rx_data, ...}`
that `:recv_pid` does. So the first bit is lost; every assembled byte is shifted
and corrupt (0x82 → committed PID 0xC1 instead of 0x2D), classification fails,
the SIE bounces to idle, enumeration never completes.

**FIX:** in the `:idle` arm (sie.ex:279-282), latch the first bit and count it,
matching `:recv_pid`:
```elixir
:idle ->
  on phy_rx_valid and phy_rx_active do
    byte_shift = {phy_rx_data, byte_shift[7..1]}
    bit_cnt    = 1
    next :recv_pid
  end
```
(bit_cnt=1 because we've now consumed the first bit; recv_pid continues from there.)

### ^ HYPOTHESIS #6 — APPLIED, TESTED, KILLED.

The fix above was applied to sie.ex:279 and verified by re-running enumeration:
```
dev_addr_max 0   cdc_dev_state_max 0   sie_rx_state_max 1   (UNCHANGED)
```
And critically, the assembled `byte_shift` sequence was **byte-for-byte identical
to before the edit** (`0x0,0x80,0x40,...,0x82`) — only `bit_cnt` shifted by one.
So latching the first bit changed nothing about the assembled byte. **The
first-bit-drop was NOT the root cause.** Edit reverted.

Why it was wrong: the *input bits themselves* (`10000011`) are already corrupt
before assembly — a mis-latch at the start cannot fix wrong bit *values*. The
alignment branch of the fork was the wrong branch.

### The remaining branch (NOT yet prosecuted): NRZI round-trip

The corruption is in the bit VALUES arriving at the SIE, so it is upstream of the
SIE entirely — in the wire round-trip:
- Host `USBHost.send_packet` NRZI-encodes 0x2D (LSB-first `10110100`) as J/K symbols.
- PHY (`fs_phy.ex`) NRZI-decodes symbols back to bits: `bit_transition =
  bxor(rxd_last_j, sym_j)`, `nrzi_rx_bit = bnot(bit_transition)` (fs_phy.ex:321-322).
- The SIE received `10000011` — NOT `10110100`.

Deterministic next step (fresh): capture the raw J/K wire symbols during the PID
field, hand-decode NRZI, and compare to (a) host intent `10110100` and (b) SIE
received `10000011`. Whichever the hand-decode matches identifies whether the
HOST ENCODE or the PHY DECODE is inverted/misaligned. Do this before any edit.

### NRZI polarity: VERIFIED CORRECT against the USB standard (web-checked)

USB NRZI truth table (standard): **0 = transition (toggle), 1 = no transition**.
Same convention for encode and decode.

- Host encode (usb_host.ex:439-445): `1 → no change, 0 → toggle`. ✓ matches standard.
- PHY decode (fs_phy.ex:321-322): `bit_transition = bxor(rxd_last_j, sym_j)`,
  `nrzi_rx_bit = bnot(bit_transition)` → no-transition=1, transition=0. ✓ matches standard.

**Both sides are individually correct. There is NO NRZI polarity bug.** A probe
that appeared to show the PHY "inverted" was a MEASUREMENT ARTIFACT: it paired
`dp_s0` on consecutive `sample_en` cycles, but the PHY decodes against its
internally-registered `rxd_last_j` latched on a different edge — so the naive
consecutive-symbol pairing was not the PHY's actual reference. (This would have
been killed hypothesis #7; the web-check caught it before any edit.)

### Remaining live suspects (narrowed by the NRZI exoneration)

With NRZI polarity ruled out on both sides, the bit-VALUE corruption
(`10000011` received vs `10110100` sent) must come from one of:

1. **Bit-stuffing / unstuffing mismatch.** USB stuffs a 0 after six consecutive
   1s; the receiver must remove it. If host stuff and PHY unstuff disagree on
   position, all bits after the first stuff point shift. NOT yet verified. Note
   0x2D=10110100 has no run of six 1s, so a SETUP PID alone shouldn't trigger
   stuffing — but SYNC + PID together might, and the mis-shift could originate at
   the SYNC→PID boundary.
2. **`rxd_last_j` sample reference / bit alignment** in the PHY — the same timing
   that fooled the probe could be a real one-symbol reference error.

Prosecute #2 first: capture `rxd_last_j`, `sym_j`, and `nrzi_rx_bit` TOGETHER on
each sample_en cycle (the PHY's own reference, not a hand-paired one) and verify
`nrzi_rx_bit` against `bnot(bxor(rxd_last_j, sym_j))` cycle by cycle — then check
those decoded bits against the host-intent stream. This uses the PHY's real
reference, avoiding the artifact that killed the polarity probe.

### ROOT CAUSE (deepest, unifying): host TX timing violates the PHY's documented pipeline-alignment contract.

Drilled the bit-value corruption to its source — a **measured lag between the
driven wire and the filtered wire**, against a **documented design contract**.

**Measured (rawwire probe):** `dp_diff` (driven) goes high at cycle 624036, but
`dp_f` (filtered, what the PHY samples) doesn't follow until 624040 — a **4-cycle
lag**. The sample instant (`sample_en=1`) at 624037 reads `dp_f=0`, the STALE
prior symbol. Every sample reads ~1 symbol behind the wire → decoded stream is a
shifted/rotated version of the sent one (that is why no sample *phase* recovered
0x2D: the problem is the pipeline delay crossing the sample point, not the
counter phase).

**Confirmed in source — the filter is exactly 4 deep** (fs_phy.ex:356-368):
`dp_diff → dp_s0 → dp_s1 → dp_p0 → dp_p1`, `dp_f` gated on p0&p1 agreeing. Lag
matches the measurement exactly.

**The documented contract (fs_phy.ex:134-149):** the PHY is explicitly designed
around this 4-deep pipeline. It expects:
- `@phase_offset 2` — extra idle clocks so the first SYNC K drives when
  `sample_cnt==2`, so `dp_f` transitions at `cnt=2≠0`, so `bit_edge` reset
  re-centers sampling.
- `@sync_wire_pattern` = **9 symbols `KJKJKJKKK`**, because "the pipeline consumes
  the first symbol before the SYNC state machine begins."

**The violation:** the host's `USBHost.drive_sync` (usb_host.ex:419) drives
`[:k,:j,:k,:j,:k,:j,:k,:k]` = **8 symbols (KJKJKJKK)**, not the 9 the PHY expects,
and the host send path applies **no `@phase_offset` idle padding**. So the host's
transmit timing does not honor the PHY's documented pipeline-alignment contract.
With SYNC one symbol short and no phase offset, the sample points land at the
wrong phase relative to the pipeline-delayed `dp_f` for the whole packet — the
~1-symbol misalignment measured end to end.

This UNIFIES every prior observation: decode self-consistent ✓, NRZI polarity
correct ✓, sample-counter phase a red herring ✓ — the bits are wrong because the
host TX timing and the PHY RX pipeline-alignment contract disagree.

**SYNC-length fix: ATTEMPTED and KILLED (hypothesis #8).** Changed `drive_sync`
to 9 symbols (KJKJKJKKK). Result: the sampled stream shifted by one symbol (so
SYNC length IS an alignment lever) but committed rx_pid values were still garbage
(`0x0 0x40 0x80 0x22 0x1 0x2 0x14`, none 0x2D); dev_state still 0. Reverted. The
SYNC-length mismatch is NOT the (whole) root cause despite matching the comment.

**Deeper measurement — it is NOT a simple delay/shift.** Measured driven-edge vs
filtered-edge correspondence directly:
```
dp_diff transitions: 624036 624044 624048 624056 624064 624068   (gaps 8 4 8 8 4)
dp_f    transitions: 624028 624040 624048 624052 624060 624068   (gaps 12 8 4 8 8)
```
The two edge patterns have DIFFERENT spacing — the filtered signal's edge
structure differs from the driven signal's. A pure pipeline delay would be a
constant shift; this is not. **The `dp_f` glitch filter (2-of-2 agreement,
fs_phy.ex:364-368) is altering WHICH transitions survive** — eating/merging edges
in a pattern-dependent way. That is why no sample-phase and no SYNC-length change
recovered 0x2D: the corruption is not alignment, it is edge-structure alteration.

**Sharpest current suspect:** the glitch filter's persistence requirement vs. the
symbol dwell time. A symbol driven for @clocks_per_bit=4 cycles, through a 4-deep
pipeline (2 sync + 2 agree), sits at the margin where a transition may not persist
long enough for the 2-of-2 filter to register — so borderline edges are filtered
out. NOT yet confirmed.

**Next (fresh eyes) — one confirming measurement, no edit:** for each driven edge
that has NO corresponding dp_f edge (an eaten edge), verify the symbol dwelled
fewer cycles than the filter's persistence window. If every eaten edge matches
that condition, the filter-persistence-vs-dwell mismatch is confirmed and the fix
is a design decision (lengthen symbol dwell, or relax the 2-of-2 to 1-of-2, or
change @clocks_per_bit vs pipeline depth). Do NOT edit until the eaten-edge
condition is verified.

### DEEPER: every isolated stage verified CORRECT — bug is an interface/handoff effect

Continued drilling with per-cycle measurement. Each stage checked deterministically:

- **PHY filter pipeline:** clean, constant 4-cycle delay. `dp_f == dp_diff@(idx-4)`
  at EVERY sample (verified 9/9). No eaten edges, no distortion. (The earlier
  "edge-structure alteration" reading was a transition-pairing mistake — killed.)
- **Sample vs driven:** `dp_f` sampled == the driven symbol every time. Faithful.
- **NRZI decode:** self-consistent (`nrzi_rx_bit == bnot(bxor(rxd_last_j,sym_j))`
  every cycle). Correct polarity per USB standard.
- **Encoder logic (`send_nrzi_bits`):** re-implemented its exact logic in isolation
  → produces `01110010` for 0x2D, the CORRECT encoding. Source read
  character-by-character (usb_host.ex:427-449): identical to the correct algorithm.
- **Symbol dwell:** run-lengths are multiples of @clocks_per_bit (4,8) — correct
  NRZI level-merging for consecutive same-bits, NOT inconsistent dwell.
- **Window/alignment:** swept all 9 window offsets of the sampled stream; NONE
  yields 0x2D's encoding `01110010`. So the wire genuinely carries wrong symbols
  (`01101100`), not a probe misalignment.

**The paradox:** every stage is individually correct, yet the wire carries
`01101100` where 0x2D should be `01110010` (they match for symbols 0-2, diverge
at symbol 3). When all components are correct but the composition is wrong, the
fault is in the INTERFACE between them — the initial condition handed across a
boundary.

**Prime remaining suspect — the SYNC→PID handoff:** `send_packet` (usb_host.ex:404)
starts PID encoding with `send_nrzi_bits(auto, pid_bits, :k, 0, c)` — asserting
the line is in state K after SYNC. SYNC (`drive_sync`) ends on `:k` logically, so
the assumption looks right — BUT the divergence begins exactly at the SYNC→PID
boundary region (symbol 3), which is where an initial-condition / continuity error
between the SYNC drive and the PID drive would manifest. NOT yet isolated. The
`last_sym` continuity between `drive_sync` → PID `send_nrzi_bits` → payload
`send_nrzi_bits`, and whether the wire/`dp_prev`/`rxd_last_j` reference is
consistent across that seam, is the next measurement.

### INSTRUMENTATION BREAKTHROUGH — TX encoder verified correct; I was reading the WRONG PACKET

Added a TX decision log (`USBHost.enumerate_with_txlog`): send_nrzi_bits now
records `{idx, field, bit, ones, stuffed, sym, ps}` per symbol — the encoder's own
record of what it drove. Also added a PHY `dbg_rx_sym` counter wire.

The log, read by packet:
```
PID#0 = 0xA5  (SOF)     PID#1 = 0x2D  (SETUP — CORRECT)
PID#2 = 0xC3  (DATA0)   PID#3 = 0x69  (IN)
PID#4 = 0xD2  (ACK)     PID#5 = 0x69  (IN)
```
**Every PID is encoded correctly, including the SETUP as exactly 0x2D.** The TX
encoder and its inputs are fully correct — proven from the encoder's own record,
not reconstructed.

**MY ERROR, exposed:** the enumeration sends a SOF (0xA5) BEFORE the first SETUP
(usb_host.ex:80). Every downstream capture tonight anchored on "first
rx_state==4" — which is the **SOF packet (0xA5)**, not the SETUP (0x2D). All the
"corruption at bit 3" analysis was diffing the SOF's bits against 0x2D's expected
bits. The device correctly received 0xA5; I was comparing it to the wrong target.
This invalidates the downstream-corruption conclusions (they measured the wrong
packet), and it explains the persistent "correct for 3 bits then diverges"
(0xA5=10100101 vs 0x2D=10110100 share the first 3 bits).

### CORRECTED STATE — the bug is NOT established; re-anchor required

What is NOW verified: TX encode chain fully correct (all PIDs). What is NOT yet
known: whether the device correctly processes the SETUP (0x2D) packet —
because we never actually captured the SETUP; we kept capturing the SOF.

**Next (properly anchored):** re-run downstream analysis anchored to PID#1 (the
SETUP), using `dbg_rx_sym` to align TX-symbol-N against RX-symbol-N. Check whether
the device decodes 0x2D correctly. Possible outcomes:
  (a) device decodes SETUP fine → the enumeration failure is elsewhere (SOF
      handling, or the device correctly NAKs and the host script mis-sequences);
  (b) device mis-decodes SETUP → real RX bug, now measured against the RIGHT
      packet for the first time.

The instrumentation (tx decision log + dbg_rx_sym) is the durable win: it cut
through the entire night's mis-anchored hand-analysis in one measurement, exactly
as predicted. Every prior "downstream corruption" finding is SUSPECT until
re-verified against PID#1.

### BOTH SIDES NOW VERIFIED CORRECT — corruption isolated to PHY→SIE handoff

Added a per-packet reset to `dbg_rx_sym` (=0 on entering :active, fs_phy.ex),
so index 0..7 = THIS packet's PID unambiguously. Decoding each packet's first 8
symbols:
```
PKT0 = 0xA5 (SOF)    PKT1 = 0x2D (SETUP ✓✓)  PKT2 = 0xC3 (DATA0)
PKT3 = 0x69 (IN)     PKT4 = 0xD2 (ACK)
```
**Every packet, including the SETUP, is RECEIVED and NRZI-decoded correctly at the
PHY symbol level (0x2D exactly).** The earlier "SETUP → 0xC1" was AGAIN a probe
window/alignment artifact, not hardware. The entire RX symbol path (wire, filter,
sample, NRZI decode) is now instrumentation-verified correct.

**The true, tight corner:** PHY decodes 0x2D correctly, but the SIE COMMITS garbage
(`0xC1, 0x80, ...`, never 0x2D). So bits are correct at the PHY's decoded output
(`nrzi_rx_bit`/`rx_data`) but wrong by the time the SIE assembles `byte_shift`.
The corruption lives in the narrow **PHY→SIE data handoff**: `rx_valid`/`rx_data`
delivery and the SIE's shift-register timing (sie.ex:285-287 shift on rx_valid).

Next: correlate `phy_rx_data` + `phy_rx_valid` + `sie_byte_shift` per-symbol during
PKT1, watching exactly where a correct decoded bit fails to land in byte_shift.
This is a MUCH smaller region than the full RX path — both endpoints are now
proven, so the fault is strictly between them.

### METHOD WIN: instrumentation + per-packet-reset counter turned an all-night
### hand-decoding morass into clean, unambiguous per-packet readouts. TX verified
### (encoder log), RX verified (per-packet PID decode). Bug cornered to one handoff.

### TWO REAL BUGS FOUND AND FIXED — mechanism-verified at the PHY→SIE handoff

Correlating phy_rx_valid + phy_rx_data + sie_byte_shift per-symbol during PKT1
(the SETUP) exposed TWO defects in the PHY's RX output logic (fs_phy.ex:348-349):

**Bug 1 — rx_valid fired once per BYTE, not per bit.**
`rx_valid = (rx_state==4) and sample_en and (bit_cnt==7) and bnot(bit_stuff_now)`
The `bit_cnt==7` gate made rx_valid assert only on the 8th bit of each group.
The SIE shifts one bit per rx_valid and keeps its OWN bit_cnt — so it received
1 bit per byte and never assembled a PID. Measured: rx_valid = `00000001` across
the 8 SETUP symbols.
FIX: `rx_valid = (rx_state==4) and sample_en and bnot(bit_stuff_now)` — pulse on
every sampled data bit. Verified: rx_valid now `11111111`, SIE bit_cnt now walks
0..7 per byte.

**Bug 2 — rx_data presented data_sr[0..0] instead of the decoded bit.**
After fixing bug 1, byte_shift still stayed 0x0: rx_data was `data_sr[0..0]`, the
LSB of the internal (MSB-filled, mostly-zero) shift register — NOT the freshly
decoded bit the SIE needs to latch.
FIX: `rx_data = nrzi_rx_bit`. Verified: byte_shift now assembles
`0x8→0x84→...→0x2D` and the SIE **commits 0x2D** (the SETUP PID) — confirmed in
the committed rx_pid list, where 0x2D now appears (it NEVER did before).

Both fixes confirmed by MEASUREMENT of the mechanism change, not inference.

### AFTER THE TWO PHY FIXES: every packet decodes cleanly

Decoding EVERY packet's PID across the enumeration (per-packet reset counter):
```
SOF SETUP DATA0 IN ACK IN ACK IN ACK OUT DATA1 SOF SETUP DATA0 IN ACK ...
```
A textbook USB enumeration transaction sequence — every PID valid and expected.
The receive path (wire→filter→sample→NRZI→SIE byte assembly) is now fully
correct. The two PHY fixes completely repaired reception.

### THIRD ROOT CAUSE — a DSL/elaborator bug: `next` inside `if` is silently dropped

With packets decoding correctly, the SIE STILL never advances past recv_pid
(sie_rx_state dist `%{0 => 624038, 1 => 55390}` — only ever 0 or 1). Measured: the
SETUP assembles as rx_pid=0x2D correctly, and the classification (byte_shift[1..2])
even routes it to `next :recv_token` correctly — yet the state never becomes
recv_token. `next` does not take effect.

Root cause in the FSM parser (lib/hw/dsl/primitives/parse/fsm.ex): there are
FSM-aware clauses for `next` (:44) and `on` (:50-89) — each recurses into its
body via `parse_fsm_statements`, so nested `next` is recognized. **But there is NO
clause for `if`.** A bare `if cond do ... next :state ... end` falls through to
:94 → plain `parse_statement`, which is NOT FSM-aware — so a `next` inside a plain
`if` is parsed as a meaningless plain statement and NO transition arc is created.

The SIE classification (sie.ex:291-301) uses `if/else`, not `on`, so its
`next :recv_token` / `next :recv_data` / `next :idle` are all silently dropped.
The device receives and classifies the SETUP correctly but can never leave
recv_pid. This is a genuine compiler bug: nested `next` works in `on` but is
silently ignored in `if`.

**FIX (design decision):**
  (a) Make the FSM parser handle `if` FSM-aware (recurse into then/else bodies
      with parse_fsm_statements), matching `on`. Correct/general fix; touches the
      elaborator's `if` handling everywhere. OR
  (b) Rewrite the SIE classification to use `on` instead of `if` (localized,
      lower-risk, but leaves the compiler footgun in place for others).
Recommend (a) with a targeted test (an FSM with `next` inside `if`), but verify
it recovers enumeration (dev_state==2) before committing.

### SESSION RESULT — THREE genuine bugs found, two fixed and verified:
1. PHY rx_valid fired per-byte not per-bit (FIXED, verified: packets now decode).
2. PHY rx_data presented stale data_sr[0..0] not the decoded bit (FIXED, verified).
3. FSM elaborator drops `next` nested inside `if` (ROOT-CAUSED, fix is a design
   choice, not yet applied).
The receive datapath is now fully correct; the last blocker is the compiler
dropping the SIE's classification transitions. Every finding is measurement- or
source-verified — no inference. Instrumentation (tx decision log + per-packet
dbg_rx_sym counter) was the decisive tool that made all of this tractable.

### FSM elaborator fix APPLIED and VERIFIED — state now advances

Added an FSM-aware `if` clause to lib/hw/dsl/primitives/parse/fsm.ex (parses
then/else bodies with parse_fsm_statements, so nested `next` produces a real
transition). AST verified empirically first: `if` desugars to
`{:if, meta, [cond, [do:, else:]]}`.

Result: `sie_rx_state` went from stuck-at-1 (dist %{0,1}) to reaching **3**. The
SIE now advances recv_pid → recv_token. This is a genuine COMPILER fix — every
`if`-nested `next` in every FSM (SIE and CDC) now works, not just this one.

### FRONTIER: token acceptance gates (protocol bring-up, receding by one each fix)

With the FSM fix, the SIE enters recv_token and assembles the token correctly for
the clean SETUP (measured: rx_addr=0, correct device address at enum start). But
`token_addr_match_reg` still never fires, so the SETUP is never accepted, and
enumeration doesn't complete. The acceptance is gated by a CHAIN of nested-if
conditions (sie.ex:336-364): `token_bits==15` → `crc5_next==0x0C` (CRC5 valid) →
`rx_addr==dev_addr` (address match) → set match/type regs.

Measured so far:
- rx_addr assembles to 0 for the clean SETUP ✓
- BUT: no token-complete cycle has rx_pid==0x2D held at completion (0 found) —
  rx_pid (set in recv_pid) is not 0x2D by the time recv_token finishes 16 bits
  later, OR the clean SETUP's token completion carries a different rx_pid.
- crc5 residual is never 0x0C at the token-complete cycles sampled (all garbage
  tokens) — the CRC5 validation gate.

This is now normal layered protocol bring-up: each acceptance gate (CRC5, addr
match, rx_pid persistence across recv_pid→recv_token) was masked behind the FSM
transition bug and behind the earlier PHY bugs.

### SIE self-instrumentation (dbg_last_pid / dbg_route / dbg_tok_fail / dbg_pid_raw)

Added debug registers so the SIE narrates its own decisions (read directly, no
offline reconstruction). Measured:
- `dbg_last_pid` (classified PID): distinct values 0x0 0x4 ... 0xFD — **never 0x2D**.
- `dbg_pid_raw` (raw arrival-order bits shifted in during recv_pid): also **never
  0x2D**; the values are PERMUTATIONS of 0x2D's bits — notably 0xB4 (= 0x2D bit-
  reversed exactly), 0x5A, 0x52.
- `dbg_route`: mostly idle, some token/data.
- `dbg_tok_fail`: 100% CRC5-fail (dbg_tok_fail=1), never address mismatch.

Cross-referenced with the PHY-level per-packet decode (dbg_rx_sym reset), which
proved every packet INCLUDING the SETUP decodes to the correct PID (0x2D) at the
wire. So: PHY has the right bits; the SIE latches them PERMUTED.

### BIT-REVERSAL HYPOTHESIS: KILLED. Real root cause = one-cycle latch latency.

The 0xB4 "bit-reversal" was a coincidence of reading a rolling shift register
one bit too early. Clean packet-aligned capture (via phy_dbg_rx_sym reset) of the
PHY's data_sr, bit by bit, for the SETUP:
```
sym6 data_sr=0xB4   sym7 data_sr=0x5A   sym8 data_sr=0x2D ✓   sym9 data_sr=0x16
```
data_sr reaches the CORRECT 0x2D at **sym8** (after all 8 bits latch), not sym7.
The "permutation" values (0xB4, 0x5A) were just the register mid-assembly.

The SIE side shows the IDENTICAL pattern: byte_shift lags rx_data by one — the
first rx_data bit isn't in byte_shift until two samples later, and the
classification at bit_cnt==7 reads byte_shift one bit SHORT (0xA4 for SOF at bc7;
the correct value appears at the next sample, bc0→0x52).

**CONFIRMED ROOT CAUSE (both PHY and SIE, same relationship):** rx_data is
combinational-current, but the consuming shift register (data_sr / byte_shift)
latches it on the NEXT clock edge. The byte-complete check (bit_cnt==7 / the sym7
read) fires one cycle BEFORE the final bit has propagated into the register. So
every byte is read one bit early — the correct value exists exactly one cycle
later (sym8, or bit_cnt wrap to 0). This is the same off-by-one glimpsed earlier
("first bit dropped at idle→recv_pid"), now proven precisely on BOTH shift
registers — not a hex guess.

**FIX:** make the SIE classify/complete the PID one cycle later — read byte_shift
after the 8th bit latches (e.g. classify when bit_cnt wraps to 0, or fold the
current rx_data bit into the classified value). Verify: dbg_last_pid == 0x2D for
the SETUP, then dev_state==2. Instrumentation (per-packet counter + both shift
registers) is what turned an all-night hex-guessing morass into this clean,
both-sides-confirmed timing diagnosis.

### FIX ATTEMPTS (two, both wrong — precise mechanism still needs a careful pass)

Attempt A: bind `pid_now = {phy_rx_data, byte_shift[7:1]}` and classify on it.
FAILED to elaborate: "Unknown signal or parameter: pid_now" — this E-HDL does
NOT support ad-hoc local bindings inside an FSM body; you may only reference
declared `wire`s (or inline the expression). DSL constraint, now known.

Attempt B: revert to classifying on byte_shift[1..2] (the complete PID's type
field). NO-OP: dbg_last_pid still never 0x2D (still 0x52 for the SOF where 0xA5
is correct). So the classification BITS were never the issue.

Precise measured mechanism (certain): the SIE's byte_shift lags rx_data by a
cycle — bc0 and bc1 both show byte_shift=0x0 while rx_data already carries bits.
So at bit_cnt==7, byte_shift holds only ~7 real bits (first bit dropped), and the
assembled PID (0x52 for SOF) is wrong vs correct (0xA5). The PHY's OWN data_sr
reaches the correct byte one sample later (sym8), confirming the SIE completes
one bit too early / drops the first bit.

The correct fix is a timing change to the bit_cnt / byte_shift update ordering in
:recv_pid (and by symmetry the same pattern likely in :recv_token, :recv_data).

### ROOT CAUSE FOUND (via AST inspection) and FIX APPLIED + VERIFIED

Inspected the elaborated IR to settle the semantics I kept mis-reasoning:
- `{phy_rx_data, byte_shift[7:1]}` → `{:concat, [{:signal,:phy_rx_data},
  {:slice, byte_shift, 7, 1}]}` — first element is MSB. Concat/slice are correct.
- sequential.ex build order: within a clocked block, all reads see the OLD
  registered value (conditions read from signal_map = current/registered). So
  `if bit_cnt == 7` reads old bit_cnt; completion timing was fine.

So the concat, slice, and completion were all correct. The trajectory then showed
the real defect: the SIE's FIRST captured bit (bc0) is a spurious value — the
`:idle → :recv_pid` transition (sie.ex:287) fires on the cycle carrying the FIRST
PID data bit, but it only sets bit_cnt=0 and transitions WITHOUT shifting that bit
into byte_shift. The first bit is consumed by the state change and dropped, so
every PID assembled one bit short (0x52 for SOF instead of 0xA5).

**FIX (sie.ex :idle arm):** shift the first bit in at the transition:
`byte_shift = {phy_rx_data, byte_shift[7..1]}; bit_cnt = 1; next :recv_pid`.
(Note: this exact fix was attempted MUCH earlier and failed — but that was BEFORE
the two PHY datapath fixes; the path was broken upstream then. Now the datapath
is clean to this handoff, so it works.)

**VERIFIED:** dbg_last_pid went from all-garbage (no valid PIDs) to including
**0xA5** (the SOF PID, correctly assembled + classified). AND tok_fail changed
from 100% CRC5-fail to CRC5-PASS + address-mismatch — i.e. the fixed byte
assembly now produces a valid CRC5. Real, measured forward motion.

### FRONTIER (moved again): SETUP/DATA0 not yet classified; address-match gate

- 0xA5 (SOF) classifies ✓, but 0x2D (SETUP) / 0xC3 (DATA0) do NOT yet — likely a
  per-packet start-alignment difference (first-bit fix corrected the idle→recv_pid
  entry; later packets may re-enter differently).
- CRC5 now PASSES (tok_fail no longer 1); the remaining token gate is ADDRESS
  MATCH (tok_fail=2), addr_match never fires.

### BUG #5 (bit-accounting off-by-one) — DETERMINISTIC INSTRUMENTATION PLAN

The recv_pid byte-completion captures the wrong number of bits. Bracketed by
dbg_active_cnt (a live per-packet bit counter):
  entry bit_cnt=1 → active_cnt=7 (one short); SOF lucky-correct, 6 clean completions
  entry bit_cnt=0 → active_cnt=8 (right count, WRONG window); garbage, 25 completions
The fix is between these — the entry shift, per-cycle increment, and the
old-value read of `if bit_cnt == 7` couple in a way that hand-counting has gotten
wrong repeatedly. STOP tweak-and-test; instead capture the full comb+seq truth.

Plan (Layers 1+2; oracle deferred):

LAYER 1 — shadow the completion-decision inputs, latched INSIDE the
`if bit_cnt == 7` block (so they capture exactly what the hardware branched on,
under old-value read semantics):
  dbg_bc_old   = bit_cnt            # the value the `if` actually read (old/registered)
  dbg_bc_next  = bit_cnt_next       # comb old+1
  dbg_bs_pre   = byte_shift         # registered, pre-shift
  dbg_bs_post  = {phy_rx_data, byte_shift[7..1]}   # comb value that will commit
  dbg_rxdata_at= phy_rx_data

LAYER 2 — per-cycle trajectory (every recv_pid rx_valid cycle), capturing BOTH
the registered and the comb-next value side by side (the missing column today):
  dbg_bit_idx  (monotonic bits-since-entry), bit_cnt(reg) vs bit_cnt_next(comb),
  byte_shift(reg) vs post-shift(comb), phy_rx_valid, phy_rx_data.
The snapshot stride:cycle capture already gives the registered column; the
addition is the comb-next column, which is what the logic actually branches on.

DERIVATION (mechanical, from one snapshot run — no arithmetic by hand):
  1. Count: does dbg_bit_idx reach exactly 8 at the cycle completion fires?
     Fires at 7 → threshold early; at 9 → late.
  2. Window: does byte_shift(comb) at completion == the known PID (0xA5/0x2D)?
     Yes → value right, latch timing off; No → shift window off. (Distinguishes
     the two bracketed failure modes.)
  3. Read timing: dbg_bc_old vs bit_cnt(reg) confirms empirically which value the
     `if` branched on.
  Correct (bit_cnt init, threshold, entry-shift) = the unique setting making
  bit_idx==8 at completion AND byte_shift(comb)==known-PID for BOTH SOF and SETUP.

Analysis-side compares against known constants (0xA5, 0x2D) — the per-packet
table via dbg_pkt_num removes the wrong-packet errors that misled prior tries.
All debug wires are write-only (never read by functional logic); safe to leave.

### LAYERS 1+2 TRUTH TABLE — the deterministic answer (reframes bug #4)

The per-cycle comb/seq capture + entry-transition dump settled it with zero
arithmetic:

Entry transition (pkt#2, SOF):
```
st=0 bc=0 bs=0xA5 rv=1 ra=1   <- STILL :idle, byte_shift ALREADY = 0xA5 (correct PID!)
st=1 bc=1 bs=0x52 rv=0        <- entered :recv_pid, byte_shift shifted to 0x52 = 0xA5>>1
```

**The complete, correct PID is already in byte_shift AT the :idle→:recv_pid
transition.** The byte is assembled BEFORE recv_pid. Then:
- My bug-#4 "shift first bit at entry" fix does `byte_shift = {rx_data,
  byte_shift[7:1]}` — shifting the ALREADY-COMPLETE 0xA5 one more time → 0x52.
  It DESTROYS the correct value.
- recv_pid then shifts 7 more times (idx 1..7: 0x52→0xA9→0x54→...), producing the
  garbage trajectory and a spurious second completion whose value overwrites
  dbg_last_pid.

**"CLASSIFY ON ENTRY" HYPOTHESIS: KILLED by per-packet check.** The 0xA5-at-entry
for pkt#2 was a COINCIDENCE. byte_shift at the :idle entry trigger, per packet:
```
pkt1: 0x0   pkt2: 0xA5(SOF ✓ lucky)  pkt3: 0x5A(=0x2D<<1, WRONG)
pkt4: 0x0   pkt5: 0x20               pkt6: 0xC
```
Only the SOF (pkt2) happens to have the right byte at entry; every other packet
does NOT. So byte_shift is NOT reliably the complete PID at :idle — the "classify
on entry" fix would be just as wrong. (Nearly applied it off a single row —
caught by the per-packet measurement. This is the recurring failure mode:
over-reading one sample.)

**Corrected state:** the correct byte must be assembled DURING recv_pid; the
question is still the exact bit-count/window there. The Layer1/2 trajectory for
pkt#2 showed bc_reg already = 7 at recv_pid idx=1 and a full re-shift sequence —
meaning bit_cnt is entering recv_pid STALE (=7 from a prior packet) and/or the
entry-shift + count is misaligned per-packet. The deterministic next step is to
read the FULL trajectory for a NON-lucky packet (e.g. pkt#3, the SETUP: entry
0x5A) — registered-vs-comb columns across all its recv_pid cycles — and find the
cycle where bs_cmb first equals 0x2D, which pins the correct completion point.
DO NOT apply a fix off entry-snapshots or single rows; use the full per-packet
trajectory.

### OUT-OF-SIM ORACLE + PARAMETER SWEEP (the fix for the recurring misread)

Root problem is NOT missing data — it's over-reading single rows. Solution: move
the JUDGMENT out of the head and into a pure Elixir analysis over the FULL trace.

Oracle design (pure FP, in .exs / heredoc — no hardware, no interpretation):
1. Reference model `reference_assemble(arrival_bits, init, thresh)`: assemble the
   captured arrival-order bit stream (from dbg_pid_raw / dbg_bit_idx) the textbook
   USB LSB-first way, parameterized by the two free knobs (bit_cnt init at entry,
   completion threshold). 4 lines, obviously correct.
2. Per-packet extraction: chunk samples by dbg_pkt_num → struct per packet
   {pkt, entry_state, bits, sie_pid=dbg_last_pid, completion_cycle, active_cnt}.
   The struct IS the answer; no eyeballing.
3. Verdict: known-PID table {0xA5 SOF, 0x2D SETUP, 0xC3 DATA0, 0x69 IN, 0xD2 ACK};
   print all_match? / first mismatch packet / diverging bit index only.
4. PARAMETER SWEEP (kills tweak-and-test): run reference_assemble over the REAL
   captured bit streams for every (init, thresh) in a grid; score = # packets
   whose reference PID == known PID; report the (init,thresh) scoring 100%. That
   winning pair IS the correct hardware fix — derived by exhaustive evaluation
   over ground truth, zero row-reading. Apply it, verify dbg_last_pid==known and
   dev_state==2.

Optional extra instrumentation (deferred; data already suffices): dbg_cycle
(free-running tick for provable ordering) + wire dbg_last_state (FSM-path
reconstruction). Not needed for the oracle.

### ORACLE + SWEEP RESULT — kills the "bit-offset" family of fixes

Built the out-of-sim oracle (pure FP over the trace):
- Oracle assembly of the PHY arrival bits, offset 0, LSB-first:
  `pkt0=0xA5 pkt1=0x2D pkt2=0xC3 pkt3=0x69 pkt4=0xD2` — PERFECT, textbook enum.
  So the PHY delivers correct bits and correct assembly is trivial (first 8,
  LSB-first).
- SIE committed (dbg_last_pid at completions): `0x0 0xA5 0x5A 0x0 0x20 0xC ...`
- SWEEP: reference-assemble the arrival bits at offset 0/1/2/3 and count matches
  vs the SIE commits → **0 packets match at EVERY offset.**

**Conclusion (deterministic): the SIE's garbage is NOT a bit-shifted/misaligned
version of the correct stream.** If it were a simple off-by-N, some offset would
score high; none does. Combined with the earlier "25 completions for 6 packets"
finding, the SIE's recv_pid is:
  (a) firing completion at WRONG times (spurious extra completions), and
  (b) re-assembling ACROSS packet boundaries (contaminating bytes).

This KILLS the entire "adjust bit_cnt by N / shift-at-entry" family of fixes I
attempted — the oracle evaluated the whole offset space and returned "none of
your theories reproduce the data." The bug is STRUCTURAL in recv_pid's
completion/re-entry timing, not a bit-count off-by-one.

The oracle infra (arrival-bit extraction + reference assembler + offset sweep,
in /tmp/oracle.exs and /tmp/sweep.exs) is now the permanent VALIDATION tool: any
candidate fix must make the SIE commits equal the oracle's per-packet PIDs. Next
work: rebuild recv_pid completion so it (1) completes exactly once per packet at
the right bit, (2) resets cleanly at packet boundaries — validated against the
oracle, not by eyeballing. NOTE: also confirm oracle-vs-SIE PACKET INDEXING
aligns (SIE emits spurious completions, so index k differs between the two
captures) before comparing element-wise.

### RECV_PID REBUILD SPEC (comb-boundary + reset-on-exit) — AST-grounded

Two elaborator facts (confirmed by inspecting sequential.ex + parse output):
  (a) All reads in a clocked block see the OLD registered value (conditions read
      signal_map = cycle-start state). Assignments commit together, non-blocking.
  (b) `{a,b}` = concat, a is MSB; each signal elaborated independently.
Corollary: writing recv_pid in implicit top-to-bottom sequential style FIGHTS the
parallel/old-value semantics — the source of every mis-located fix tonight.

Rebuild principle: stop COUNTING to a fragile inline `== 7`; make the boundary an
explicit comb signal, and make reset structural (on state exit), not inline.

STRUCTURE:
1. comb: `pid_complete = (bit_cnt == THRESH)` — one clearly-defined old-value
   signal owns "byte done this cycle". (THRESH is a knob, see below.)
2. recv_pid, on phy_rx_valid: ALWAYS shift + count, both from old values:
     byte_shift = {phy_rx_data, byte_shift[7..1]}
     bit_cnt    = bit_cnt_next
   The complete byte on the pid_complete cycle is the comb value
   {phy_rx_data, byte_shift[7..1]} (this cycle's bit + 7 old bits).
3. on pid_complete: classify {phy_rx_data, byte_shift[7..1]}; next
   :recv_token/:recv_data/:idle. Do NOT reset bit_cnt here.
4. RESET-ON-EXIT: bit_cnt (and byte_shift if needed) reset in the ENTRY of the
   next state (recv_token/recv_data/idle), so recv_pid structurally CANNOT
   double-fire. This directly fixes the oracle-proven "25 completions for 6
   packets" + cross-packet contamination — the actual bug.
5. ENTRY: :idle→:recv_pid does `bit_cnt = INIT; next :recv_pid` and does NOT shift
   (recv_pid owns all 8 shifts, symmetric, no first-bit-drop ambiguity).

THE CONSTANT (INIT, THRESH): do NOT hand-derive (that failed repeatedly). Encode
the rewritten logic's exact semantics in the oracle reference model and SWEEP
(INIT, THRESH) over the captured arrival bits in pure Elixir (ms, no recompile);
the pair scoring 100% vs known PIDs is the answer. Apply to HDL, verify SIE
commits == oracle per packet, then dev_state==2.

Synthesis: STRUCTURE from reading the elaborator (comb boundary, reset-on-exit,
old-value-safe); CONSTANT from evaluating the data (oracle sweep). Neither from
hand arithmetic.

### RECV_PID REBUILD — implemented; exposed an INPUT-STREAM mismatch (oracle used wrong signal)

Implemented the comb-boundary rebuild: bit_cnt widened 3→4, entry sets bit_cnt=0
+ clears byte_shift (reset-on-entry), recv_pid owns all 8 shifts, complete at
bit_cnt==8. The (init=0, thresh=8) came from the oracle sweep (11/11 vs known).

Reset-on-entry fix VERIFIED at the register level: HDL byte_shift now starts at
0x0 at bc=0 and shifts cleanly 0x0→0x80→0xC0→...→0xB (was starting from prior-
packet residue 0x29). So the rebuild structure is correct.

BUT the assembled PID is still wrong (0xB, not 0xA5). Root: the bits the SIE
actually shifts (phy_rx_data at its phy_rx_valid cycles) = 1,1,0,1,0,0,0,0 —
which is NOT the SOF's correct LSB-first stream 1,0,1,0,0,1,0,1.

**KEY REALIZATION:** the oracle/reference model was built on `phy_nrzi_rx_bit`
sampled at `phy_sample_en` (the PHY's INTERNAL decoded bit) — but the SIE consumes
`phy_rx_data` gated by `phy_rx_valid` (the HANDOFF signal). These are DIFFERENT
streams / different timing. So (init=0, thresh=8) is correct for the oracle's
input but the HDL runs on the real handoff input, which is mis-timed.

So there's ANOTHER layer: phy_rx_data / phy_rx_valid (the SIE's actual input) does
not equal the PHY's internally-correct nrzi_rx_bit stream. The rx_data=nrzi_rx_bit
fix set the VALUE right but the per-rx_valid SAMPLING the SIE does picks bits at
the wrong phase. Next: rebuild the oracle on the SIE's TRUE input
(phy_rx_data @ phy_rx_valid), re-sweep, and/or fix the rx_valid/rx_data handoff
timing so the SIE samples the same bits the PHY decoded. The rebuild + oracle
infra are correct METHOD; the model just needs the SIE's real input signal.

### SIE-INPUT ORACLE — decisive: the bug is UPSTREAM in the rx_valid/rx_data handoff

Added dbg_rxd_stream (SIE captures phy_rx_data on each rx_valid, exactly as it
consumes — narrates its own INPUT). Compared to the PHY's correct decoded stream:
```
PHY arrival PIDs:      0xA5 0x2D 0xC3 0x69 0xD2   (PHY decodes CORRECTLY)
SIE consumed streams:  0x52 0xB                    (SIE's ACTUAL input — WRONG)
```
**Confirmed: the SIE consumes DIFFERENT bits than the PHY decodes.** The
rx_valid/rx_data handoff delivers 0x52-ish where the PHY decoded 0xA5. So the
whole recv_pid bit-accounting rebuild was fixing the WRONG LAYER — the input to
recv_pid is already corrupt.

This means: rx_data = nrzi_rx_bit set the bit VALUE right, but the rx_valid
timing / the phase at which the SIE latches rx_data does not align with the PHY's
per-bit decode. The SIE and PHY disagree on WHEN each bit is valid.

**Caution:** the recv_pid rebuild (bit_cnt widened to 4, complete at ==8,
reset-on-entry) ALSO destabilized completions (only 2 completions vs ~25 before)
— it's now BOTH mis-counting AND fed wrong input. The rebuild targeted the wrong
layer and should be reverted to the last-verified-good state (bit_cnt=1 version:
SOF-correct, 6 clean completions) until the handoff is fixed. Do NOT stack a
recv_pid rebuild on top of a broken input.

**CONFIRMED next target:** the phy_rx_valid / phy_rx_data handoff timing in fs_phy
— make the SIE latch the SAME bit the PHY decoded (align rx_valid pulse to the
settled nrzi_rx_bit). Build the oracle on phy_rx_data@phy_rx_valid (dbg_rxd_stream
already captures it) and fix fs_phy so SIE-consumed == PHY-decoded per packet.

### HANDOFF ORACLE — OVERTURNS the input-mismatch claim. SIE input is CORRECT.

Built a raw-stream handoff oracle comparing the two candidate input streams
DIRECTLY (not through recv_pid):
  A = nrzi_rx_bit @ sample_en (PHY decode, known correct)
  B = rx_data @ rx_valid       (what SIE consumes)
Result:
```
A len=928 first16=1010010100000000
B len=928 first16=1010010100000000   -> IDENTICAL
len diff = 0 ; offset 0: 64/64 bits match (all other offsets ~43/64)
```
**The two streams are byte-identical, 928/928, zero phase offset. The SIE's input
is PERFECT.** There is NO handoff/phase bug.

CORRECTION: the earlier "SIE consumes 0x52 where PHY decoded 0xA5" was a
MEASUREMENT ARTIFACT — dbg_rxd_stream was read at completion cycles that the
recv_pid REBUILD had destabilized (only 2 completions), so the read window was
wrong. Reading the raw stream (not through recv_pid) shows the input is fine.

**This oracle PREVENTED a wrong fix** — I was about to rewrite the fs_phy handoff,
which is correct. The real, now-confirmed situation:
  - SIE INPUT is correct (928/928 bits).
  - The recv_pid REBUILD (bit_cnt→4, ==8, reset-on-entry) destabilized completion
    (2 vs ~25) and did NOT fix assembly. It made things worse and must be REVERTED.
  - The original bug is genuinely in recv_pid assembly/counting on GOOD input.

**Next:** revert the recv_pid rebuild to last-verified-good; then, with the input
proven correct and the SIE-consumed-stream oracle (dbg_rxd_stream, now trustworthy
once completions are stable) as the checker, fix recv_pid assembly so
dbg_last_pid == known PID per packet. The reference-model sweep is still valid but
must run on stream B (= stream A, since identical) and against a STABLE completion.

### 5-ITEM PROBE SET — localizes the recv_pid regression precisely.

Wired 5 Zabbix-style calculated items (tmp_items5.exs). Result:
```
 pkt | bit_ceiling | valid.gap(act,idx) | pid  | residue(bs,bc)
   1 |      9      | act=9 idx=9 gap=0  | 0x52 | bs=0x0  bc=0
   2 |      9      | act=9 idx=9 gap=0  | 0x52 | bs=0x29 bc=9
ITEM1 entries=2 ; distinct PIDs = [0x52, 0xB]
```
READINGS:
- ITEM1 entry.count=2 — recv_pid is ARMED only twice. Matches the "2 vs ~25"
  completion regression EXACTLY. The rebuild broke ENTRY, not assembly.
- ITEM3 valid.gap=0 both entries — when recv_pid IS running it sees every pulse
  (act==idx). So no missed-bit / late-entry mid-packet problem. Input is consumed
  1:1, consistent with the handoff oracle (input is bit-perfect).
- ITEM2 bit_ceiling=9, NOT 8 — the counter climbs to NINE before completion fires.
  The `if bit_cnt == 8` gate reads the OLD registered bit_cnt, so completion lands
  one cycle late and byte_shift has shifted one bit too many => assembled PID is
  0x52 (a one-bit-rotated/late-sampled 0xA5-family value), NOT 0xA5.
- ITEM5 residue — pkt1 entry bs=0x0 bc=0 (clean), but pkt2 entry bs=0x29 bc=9.
  The reset-on-entry does NOT take effect as seen by the completion check: pkt2 is
  entered with bc=9 residue from pkt1. Old-value-read semantics: the entry arm's
  `bit_cnt=0` write is not visible to the SAME cycle's downstream reads, and the
  ==8 comparison is off-by-one against a counter that overruns to 9.

ROOT CAUSE (now specific): the rebuild's completion gate `if bit_cnt == 8` is
off-by-one against the old-value-read counter. bit_cnt reaches 9 (ceiling) because
the compare reads the pre-increment value; completion fires a cycle late; byte_shift
over-shifts by one => PID = 0x52 not 0xA5. And entry-reset residue (bc=9) leaks
into the next packet, which is why only 2 entries ever arm (the FSM never cleanly
returns to a state that re-arms idle->recv_pid).

FIX DIRECTION (matches the ORIGINAL last-good design): complete on bit_cnt==7 using
bit_cnt_next (the comb old+1) as the trigger, NOT old bit_cnt==8. i.e. revert the
rebuild's widen-to-8 gate to the last-good `bit_cnt_next == 8` / `bit_cnt == 7`
comb-boundary completion, keeping the reset-on-entry. The 5 items give the exact
acceptance test: ITEM1 must return to ~25, ITEM2 ceiling must be 8 not 9, ITEM4
PIDs must be A5 2D C3 69 D2.

NOTE ITEM4 total=55354 is a counting artifact (dbg_route is sticky/registered so it
reads nonzero on every subsequent snapshot row); the per-entry `pid` column is the
trustworthy read. Fix: gate the completion-count on a rising edge of dbg_route, or
count distinct dbg_pkt_num with route!=0. Cosmetic — does not affect the diagnosis.

### FIFTH BUG FIXED (proven by 10-item bit-dump): recv_pid one-bit drop.

The 10-item shift matrix (tmp_items10.exs) produced the bit-by-bit assembly dump
that finally settled it — no more asserting the theory, it's measured:
- ITEM1/3/4: input is 0xA5 at PHY-out AND SIE-in; bitstuff mask 00000000
  (phase-slip DISPROVEN). Reversal DISPROVEN by ITEM9 (rev(0x52)=0x4A != 0xA5).
- ITEM7 pre-fix trajectory: 00→00→80→40→20→90→48→A4, latch=0x52. The register
  stayed 0x00 for TWO steps and topped at 0xA4 — one shift short of 0xA5.
ROOT CAUSE: the idle->recv_pid transition saw the FIRST PID bit on phy_rx_data but
did `next :recv_pid` WITHOUT shifting it. Bit 0 was dropped; the whole PID slid one
position => assembled 0xA4, latched 0x52.
FIX (sie.ex idle arm): shift bit 0 in AT ENTRY and enter recv_pid with bit_cnt=1,
byte_shift already holding bit 0 in the MSB. recv_pid then shifts bits 1..7; the
bit_cnt_next==8 comb-boundary latch fires on the true 8th bit.
VERIFIED post-fix:
- ITEM7b comb_latch_val @bit_idx7 = 0xA5  (was 0x52)
- ITEM8b dbg_last_pid = [0xA5,0xA5,...]   — SOF PID now latches correctly.

STILL OPEN (do NOT call enumeration solved yet):
- Only 0xA5 (SOF) observed latching — schedule is mostly SOF heartbeat. Need to
  confirm 2D/C3/69/D2 classify on the token/data path.
- ITEM10 CRC5 residue filter over-collects intermediate values; needs per-token
  end-of-token gating to confirm 0x0C lands cleanly.
- Success criterion unmet until dev_state reaches 2 and dev_addr reaches 1.

### 12-REGION ORACLE — loopback hypothesis DEAD; fault is CRC5, not entry.

Ran the 12-region transaction oracle (tmp_regions12.exs). Walking the causal chain:
- R1 entry_via = {1 => 55390} ONLY. ZERO via=2/3 loopback entries. The
  loopback-bit-drop hypothesis is DISPROVEN — token/data never re-enter recv_pid.
- R4 rx_state reaches token(3) and data(2): FSM traverses the transaction.
- R5 token_bits climbs 1..15 cleanly (4 each): TOKENS COMPLETE. Counter fine.
- R6 rx_addr = 0x0 (correct at enum start, host addresses device 0).
- R7 crc5_at = 0x15, NEVER 0x0C.  <-- THE FAULT.
- R8 tok_fail = {0:…, 1:55034}: reason 1 = CRC5-FAIL on every token. Never reason 2
  (addr mismatch). (rxaddr,devaddr)=(0,0) WOULD match — address logic is fine.
- R9/R10/R11/R12 all zero: no valid crc16, no ep_out, no handshake/ACK, dev_state=0.
  All DOWNSTREAM symptoms of the R7 CRC5 rejection.

ROOT CAUSE (new region): CRC5 residue computes 0x15 instead of 0x0C. Tokens assemble
(R5) and address is correct (R8), but CRC5-over-token does not validate, so every
token is rejected (tok_fail=1) and enumeration cannot start. CRC5 is an INDEPENDENT
judge (lands on 0x0C only when token bits are correct) — 0x15 means the CRC5 engine
is fed wrong bits or clocked wrong relative to the token shift.

NEXT: instrument the CRC5 feed — is crc5_bit_in tapping the same bit/phase as the
rx_addr/rx_ep shift? Check crc5 seed (should init 0x1F at token start), bit order,
and whether the PID byte is (in)correctly included in the CRC5 span. The SOF PID fix
is still valid & independent of this.

### CRC5-FEED ORACLE — CRC5 hardware EXONERATED; garbage PID is upstream cause.

Per-bit CRC5 oracle (tmp_crc5.exs) cross-checked hardware crc5_next against the
module's OWN reference impl (CRC5.next) over the exact fed bits:
- Every bit: crc5_next == ref_next (10111,01011,...,10101 all match). HW CRC5 correct.
- SEED CHECK: crc5_reg==0x1F at token_bits==0. Correct.
- SPAN CHECK: token_bits 0..15, exactly 16 bits fed. Correct span.
- => CRC5 datapath, seed, and span are ALL correct. HW is NOT broken.

BUT the fed bit sequence = [0,0,0,0,0,0,0,0,0,0,0,0,0,1,0,0] — near-all-zeros,
NOT a real token payload. CRC5.compute over it = 0x15, matching HW exactly. So HW
faithfully CRC's GARBAGE INPUT.

SMOKING GUN: rx_pid at this "token" = 0x5A (NAK) — NOT a valid token PID
(SETUP=0x2D IN=0x69 OUT=0xE1 SOF=0xA5). recv_token was ENTERED off a mis-assembled
non-token PID, then fed CRC5 a non-token bitstream => residue 0x15, never 0x0C.

RE-LOCALIZED (upstream, again): the R7 CRC5 failure is a SYMPTOM. Root cause is the
STILL-OPEN non-SOF PID mis-assembly: SOF(0xA5) fixed, but SETUP/IN tokens assemble
to garbage (0x5A etc.), which (a) routes wrong and (b) drags garbage through CRC5.
Chain: bad PID assembly -> wrong classify -> recv_token on non-token -> CRC5 0x15
-> tok_fail=1 -> no accept -> dev_state stuck 0.

NEXT: why do non-SOF PIDs mis-assemble when SOF now works? All entries are via=1
(idle) per R1 — so SETUP/IN packets ALSO enter recv_pid via idle, same fixed path.
Yet SOF->0xA5 (correct) and SETUP->0x5A (wrong). Difference must be in the BITS
themselves at recv_pid for those packets: instrument the recv_pid bit-dump for a
NON-SOF packet (filter dbg_last_pid != 0xA5) and compare its 8 consumed bits to the
PHY nrzi ground truth for that same packet.

### NON-SOF BIT-DUMP — the "garbage PID" is a PHANTOM packet on idle line.

Three-tap dump of the first non-SOF packet (pkt_num=3, latched 0x10):
- SIE recv_pid consumed bits: byte_shift stays 0x00 for 4 idx then 0x80,0x40,0x20
  (assembles 0x10 from near-empty input).
- PHY nrzi GROUND TRUTH for this packet: nrzi = 000000001000 — NEARLY ALL ZEROS.
  first8 as byte = 0x00. NOT a valid PID (SETUP would be 0x2D=00101101).
- stuff = 000000000000 — no bit-stuffing. PHY genuinely decoded ~zero bits.

INTERPRETATION: pkt_num=3 is NOT a corrupted SETUP. The SIE armed recv_pid on the
IDLE/EOP GAP (NRZI all-no-transition = idle J) and manufactured a PHANTOM packet.
The "garbage PIDs" (0x10, 0x5A, 0x3, 0xC...) are phantom triggers on non-packet line
states, which then poison classify + CRC5 downstream.

REFRAME: not "SETUP mis-assembles" but "SIE starts receiving during gaps and makes
phantom packets." Two things to confirm before fixing (do NOT over-read one packet):
  (1) is pkt3 in an idle gap? check rx_state/line right before it (clean SYNC or junk).
  (2) DOES THE SCHEDULE EVEN SEND SETUP/IN? If the stimulus is SOF-only, there are no
      real tokens to assemble and the true bug is "SIE arms on idle" + "no enumeration
      stimulus." Must verify the drive schedule actually issues a SETUP transaction.

### SETUP-SPAN DUMP — phantom-packet theory OVERTURNED; real SETUP bits arrive.

Used the recorded phase spans (not pkt_num ordering) to look INSIDE the real SETUP
window (from=13027666176 to=13044831744, 794 samples). Span labels present:
[:reset, :get_descriptor, :setup, :in_data, :set_address, :get_descriptor_addr1,
:set_configuration] — so the full enumeration IS driven, SETUP included.

PHY nrzi inside the SETUP span, first24 = 101101000000000000001000. First 8 = 10110100.
- This is REAL structured data, NOT all-zeros. => last turn's "phantom packet on idle"
  interpretation was WRONG — that pkt3 dump caught a PRE-setup window, not the SETUP.
  Using phase spans instead of pkt_num fixed the mis-attribution.
- SIE inside this span: rx_state freq {0:8,1:287,2:435,3:64}; pids latched =
  [0x10,0x5A,0xC,0x3] — never 0x2D. Real SETUP bits in, garbage PIDs out.

LEAD (NOT yet asserted — burned on shift-vs-reversal twice already): first8 nrzi
10110100 vs SETUP PID 0x2D=00101101 — these are BIT-REVERSES of each other. Could be
reversal, could be a shift, could be SYNC-alignment consuming wrong # of bits before
this token. SOF path works, so whatever differs for SETUP is the key.

NEXT: three-tap bit dump (same method that nailed SOF) ANCHORED to this SETUP span's
time window: PHY nrzi vs SIE byte_shift assembly bit-by-bit. Determine reversal vs
shift vs SYNC-misalignment before touching code. Also check: does the SETUP token's
SYNC get detected at the same phase as SOF's, or is rx_state==4 entered mid-SYNC?

### ENTRY PROBES (steps 1-2) — rule out handoff + carried-state; find LSB/MSB.

P1/P2/P4 dump across get_descriptor, setup, set_address spans:
- STEP1: nrzi first16 == rxdata first16 (1011010000000000) EVERY span. PHY-out ==
  SIE-in. Handoff clean, ruled out.
- STEP2: entry state (lastj,ones,scnt) = (0,1,0) IDENTICAL for all entries incl
  SETUP vs SOF. Class A (stale carried state) RULED OUT — SYNC entry is uniform.

KEY: P1 nrzi byte0 = 10110100 = 0xB4 UNIFORMLY across all tokens. The anomaly is at
the PHY nrzi OUTPUT, not the SIE. And rev8(0xB4) = 0x2D = SETUP PID.
USB transmits LSB-FIRST. On-wire order of 0x2D is 10110100 = 0xB4 read MSB-first.
=> HYPOTHESIS (class C, specific): bit-ENDIANNESS mismatch. The datapath assembles
MSB-first but USB is LSB-first. SOF 0xA5=10100101 is NOT a palindrome either
(rev=0xA5? 10100101 reversed = 10100101 — 0xA5 IS its own reversal!) which is
EXACTLY why SOF "works" and SETUP doesn't: 0xA5 is bit-symmetric, so LSB/MSB give
the same byte; 0x2D is not, so it comes out 0xB4.

THIS EXPLAINS EVERYTHING: SOF passed by coincidence (0xA5 palindrome). Every
non-palindrome PID (2D,C3,69,D2...) mis-decodes under MSB-first assembly.

NEXT (step 4, P8): confirm on the nrzi stream directly — rev8 maps each token's
byte0 to its true PID; check 0xA5 self-symmetry; then the fix is bit-order in the
assembly (data_sr / byte_shift), NOT the entry. Verify by crc5_at==0x0C + dev_state.

### P8 ORIENTATION MATRIX — LSB/MSB endianness CONFIRMED across all tokens.

Root cause PROVEN (tmp_p8.exs), not hypothesized:
  span              nrzi8      MSB-asm  rev8      PID
  get_descriptor    10110100   0xB4     0x2D      SETUP  ✓
  setup             10110100   0xB4     0x2D      SETUP  ✓
  in_data           10010110   0x96     0x69      IN     ✓
  set_address       10110100   0xB4     0x2D      SETUP  ✓
  set_configuration 10110100   0xB4     0x2D      SETUP  ✓
Every token's MSB-assembled byte rev8's to its correct PID.
Self-symmetry: rev8(0xA5)=0xA5 (TRUE, palindrome) ; rev8(0x2D)=0xB4 (FALSE).

ROOT CAUSE: USB is LSB-FIRST on the wire; the datapath assembles MSB-FIRST. SOF
(0xA5) is the ONLY bit-symmetric PID, so it alone appeared to work — the coincidence
that masked this bug the whole marathon. Every non-palindrome PID comes out reversed.

FIX SCOPE QUESTION (resolve before editing): the MSB-first shift {new, reg[hi:1]}
pattern appears in MULTIPLE sites — PHY data_sr, SIE byte_shift (PID), rx_addr, rx_ep,
recv_data payload. Fixing one layer half-fixes it. Determine the single correct layer
(most likely PHY data_sr / the bit fed as nrzi_rx_bit MSB vs LSB) OR flip assembly to
LSB-first ({reg[hi:1]... } -> {..., new} with new in LSB) consistently at every shift
site. Verify with theory-free judges: crc5_at==0x0C AND dbg_last_pid==0x2D AND
dev_state->2 AND dev_addr->1.

### LSB-FIRST EDIT APPLIED — half-working; shift-left not accumulating.

Flipped all SIE shift sites MSB-first {new, reg[hi:1]} -> LSB-first {reg[hi-1:0], new}
(byte_shift recv_pid+recv_data, rx_addr, rx_ep, ep_out_data, dbg streams). Entry now
byte_shift = phy_rx_data (bit0 into LSB). Compiles clean.

RESULT: PIDs changed 0x10/0x5A/0xC/0x3 -> 0x1/0x2/0x3 (edit IS taking effect) but
still WRONG; crc5 still != 0x0C; dev_state still 0.

PER-BIT DUMP shows the real problem — register never accumulates:
  bit_idx: 1->0x1  2->0x0  3->0x1  4->0x0  5->0x0  6->0x1  7->0x0
It toggles in BIT 0 ONLY. The left-shift {byte_shift[6:0], phy_rx_data} is NOT
shifting existing bits up — byte_shift[6:0] reads back ~0 each cycle.

SUSPECT (needs AST/elaborator check, do NOT blind-edit again): either
 (a) entry `byte_shift = phy_rx_data` (1-bit RHS) mis-sets byte_shift's effective
     width so [6:0] slice truncates, or
 (b) concat {reg[6:0], bit} width/old-value handling differs from {bit, reg[7:1]}.
The MSB-first form {new, reg[7:1]} worked (SOF assembled), so the DSL handles that
idiom; the left-shift idiom may need explicit width or a different slice form.

NEXT: inspect elaborator concat-width + slice semantics for the left-shift idiom
before editing. Diagnosis (LSB-first endianness) remains CONFIRMED; only the HW
expression of the shift-left needs to match DSL semantics.

### MUX-WIDTH BUG FOUND (via IR) + shift-direction flip was BACKWARDS.

IR inspection: byte_shift Reg driver was _mux width=1. Cause: my entry edit
`byte_shift = phy_rx_data` (bare 1-bit RHS) collapsed the FSM mux to 1 bit,
truncating EVERY byte_shift assignment to its LSB (register stuck 0x0/0x1).
FIX: entry must be explicitly 8-bit -> `{0[6:0], phy_rx_data}`. After that the
register ACCUMULATES correctly (dump: 0x1->0x2->0x4, clean left-shift). Good lesson:
a 1-bit assignment anywhere in an FSM-driven reg silently narrows the whole mux.

BUT — re-examination shows my LSB-first FLIP WAS BACKWARDS. Building left-shift
(new bit -> LSB) puts the FIRST received bit in the HIGHEST position after 8 shifts
= MSB-first output. The ORIGINAL idiom {new, reg[7:1]} (new->MSB, right-shift) walks
the first bit DOWN to bit0 = LSB-first-correct. So the original shift was already
LSB-first-correct.

IMPLICATION: the 0xB4=rev(0x2D) coincidence led me to misdiagnose. SOF worked
because palindrome; the OTHER PIDs fail for a reason NOT yet found. Post-flip PIDs
= [0xA5,0x8,0x5A,0x30,0xC0,...] — 0xA5 correct again, others still wrong, dev_state=0.

ACTION: revert the shift-direction flip (restore {new, reg[7:1]} everywhere), KEEP
the width fix ({0[6:0], phy_rx_data} entry stays 8-bit but in the ORIGINAL MSB-first
sense: {phy_rx_data, 0[6:0]}). Then RE-OPEN the non-SOF question with a fresh
three-tap dump — the real non-SOF bug is still unidentified. Do NOT trust the
endianness theory; it was a coincidence-driven misread.

### BRUTE-FORCE SWEEP — LSB-first CONFIRMED as the sole transform (data-picked).

Swept 4096 transform combos (bit-order × offset × polarity × nibble × xor × rotate ×
stuff) over 5 token spans, ranked by #spans decoding to the CORRECT expected PID.
WINNER, 5/5 correct, simplest combo:
  order=LSB  off=0  pol=norm  nib=false  xor=0x00  rot=0  stuff=keep
    get_descriptor->0x2D SETUP  setup->0x2D  in_data->0x69 IN
    set_address->0x2D  set_configuration->0x2D   ALL ✓EXPECT
MSB order appears in NO 5/5 combo. Other 5/5 rows (xor0xFF+rot4, nib+rot4) are
algebraic aliases of the same LSB decode — they confirm, not contradict.

CONCLUSION: the endianness diagnosis WAS correct. LSB-first is the sole needed
transform. Last pass's failure was IMPLEMENTATION (1-bit mux-width collapse from a
bare `byte_shift = phy_rx_data`), NOT the theory; and my "original MSB shift was
already LSB-correct" reasoning was WRONG — the sweep shows MSB never scores 5/5.

FIX (now certain): assemble byte LSB-first at all SIE shift sites, with EXPLICIT
8-bit width so the FSM mux stays 8 bits. LSB-first shift-left idiom:
  byte_shift = {byte_shift[6..0], phy_rx_data}   # accumulates, verified 0x1->0x2->0x4
  entry seed = {0[6..0], phy_rx_data}            # explicit 8-bit, bit0 in LSB
Apply to byte_shift (recv_pid+recv_data), rx_addr, rx_ep, ep_out_data. Then judges:
crc5==0x0C, dbg_last_pid==0x2D, dev_state->2, dev_addr->1.

### SETUP TRAJECTORY — real bug is FRAGMENTED RECEPTION, not bit-order.

Per-bit dump anchored to the :setup span (794 samples):
- PHY nrzi (all)   = 10110100 000000000000  <- real PID 8 bits, THEN idle zeros.
- stuff mask       = all 0 (no stuffing).
- rx_valid gated   = 1011010000000000       <- SIE consumes the 8 PID bits + zeros.
- SETUP span touches pkt_nums [4,5,6,7,8,9,10,11,12,13] — TEN recv_pid entries in
  ONE SETUP transaction (should be ~2: token + DATA). All via=1 (idle-entry).
- Per-pkt trajectory rows EMPTY: each recv_pid episode is only 1-2 cycles — too
  short to assemble 8 bits — because recv_pid keeps RE-TRIGGERING.

ROOT CAUSE (re-localized, decisive): recv_pid is ENTERED MANY TIMES per packet. The
idle->recv_pid trigger (phy_rx_valid and phy_rx_active) fires spuriously during the
packet / its idle tail, so no single recv_pid episode ever sees all 8 real bits in a
row. The "garbage PIDs" are zeros+fragments assembled across false triggers.

REVISION OF PRIOR THEORY: the LSB-first work was CORRECT and necessary (sweep proved
the DECODE order), but it was never the reason hardware failed. The failure is
fragmented reception: recv_pid retriggers ~10x/packet. This is why byte_shift never
holds a full PID even with an 8-bit mux.

NEXT: count recv_pid entries per real packet; find WHY idle->recv_pid re-arms mid
packet (phy_rx_active drops/reasserts? phy_rx_valid glitch? SIE returns to idle and
re-triggers on the idle-tail zeros?). Instrument rx_active/rx_valid continuity across
one packet. The fix is likely a latch/gate so recv_pid runs ONCE per rx_active pulse.

### CONTINUITY TRACE + OFF-BY-ONE FIX — SETUP now decodes; multiple gates cleared.

Per-cycle continuity trace across one SETUP packet OVERTURNED the fragmentation
theory. phy_rx_active stays 1, sie_rx_state stays 1 (recv_pid) continuously, pkt=4
throughout — NO retriggering (the pkt 4..13 were OTHER packets in the span). And the
byte_shift trajectory was PERFECT:
  bit_cnt: 1->0x0 2->0x1 3->0x2 4->0x5 5->0xB 6->0x16 7->0x2D  8->0x5A
recv_pid assembles 0x2D (SETUP) correctly at bit_cnt==7. But the latch fired at
bit_cnt_next==8 reading the COMB value {byte_shift[6:0],rx_data} = a spurious 9th
shift => 0x2D became 0x5A. Classic off-by-one, reintroduced by the LSB-first rewrite.

FIX: at completion, latch the REGISTERED byte_shift (holds 0x2D), not the comb shift.
RESULTS after fix (12-region judges):
  R3: dbg_last_pid set now INCLUDES 0x2D (SETUP) — was never present before.
  R7: crc5_at now includes 0x0C — token CRC5 residue LANDS (was never 0x0C).
  R10: ep_out_valid = 89 pulses (was 0) — SETUP payload reaches the CDC endpoint.
  R8: real accepts (tok_fail=0) now mixed with the crc5-fails.
STILL BLOCKING full enumeration:
  R11: send_handshake=0, NO ACK (0xD2) back to host -> host won't advance.
  R12: dev_state still 0.
  R3 still has garbage PIDs (0x52 etc.) mixed in -> not every packet decodes clean;
      0x52 = old over-shift signature, another path may still latch comb not reg.

NET: off-by-one fix unblocked token->CRC5->endpoint (3 gates: CRC5 0x0C, ep_out 89,
accepts). Remaining: (1) missing ACK/handshake arm after valid SETUP, (2) residual
per-packet mis-decodes. Enumeration criterion (dev_state=2, dev_addr=1) still unmet
but path is now substantially open.

### CONSOLIDATION — clean-room oracle reveals SCATTERED per-packet decode.

Reverted 2 speculative edits (recv_data latch, token-PID guard) back to ep_out=89
state; KEPT the recv_pid off-by-one fix (verified good). Built a clean-room oracle
that dedupes PID per packet (killed the sticky-register phantom 0x17 x53641).

TRUE per-packet decode (18 packets): 0x2 x4, 0x9 x2, 0x10 x2, 0x20 x2, 0x52 x2,
0x65 x2, 0x2C x1, 0x2D SETUP x1, 0x60 x1, 0x79 x1. => ONLY 1/18 packets yields a
valid PID (0x2D). The earlier "SETUP decodes" was REAL but RARE.

KEY INSIGHT from consolidation: the mis-decodes are SCATTERED (all different values),
NOT systematic. A fixed bit-transform bug (endianness/shift) would corrupt EVERY
packet the SAME way. Scatter => per-packet SAMPLING/ALIGNMENT variance, not bit order.
And this RECONCILES with the brute-force sweep, which decoded the raw PHY nrzi 5/5
LSB-first: the sweep used CLEAN PHY bits; the SIE gets scatter. So corruption is
BETWEEN PHY nrzi and SIE assembled byte = HANDOFF TIMING per packet, not decode order.

JUDGES now: ep_out=89, send_handshake=0 (no ACK), dev_state=0. tok_fail {0:624626,
1:54802} — crc5 fails dominate because most packets mis-assemble.

NEXT (clean target): per-packet, compare the 8 PHY nrzi bits (rx_state==4,sample_en)
to the 8 SIE-consumed bits (rx_data@rx_valid) AND the assembled byte_shift, for
MULTIPLE packets, to find why some align (0x2D) and most don't. Likely rx_valid
phase vs recv_pid entry timing drifts per packet. This is the handoff oracle re-run
per-packet, not per-span. DO NOT chase individual garbage values — find the alignment
variance pattern.

### PKT1 CYCLE DUMP — ROOT CAUSE: completion fires before byte_shift settles.

Per-packet oracle first showed A==B for ALL packets (PHY nrzi == SIE-consumed bits):
the handoff is CLEAN, no timing variance there. The "per-packet handoff variance"
hypothesis is WRONG.

Full cycle dump of pkt1 (SOF, PHY bits 10100101 = 0xA5, correct) is decisive:
  bcnt bidx byte_shift
   1    1   0x1
   ...
   7    7   0x52     <- pre-final
   8    8   0xA5     <- COMPLETE, correct PID   (route fires here, but latch grabbed 0x52)
The register DOES assemble 0xA5 correctly — at bit_cnt==8. But the completion
condition bit_cnt_next==8 fires at old bit_cnt==7 (the 0x52 row), one cycle EARLY,
latching the pre-final 0x52.

BUT pkt3 (SETUP) latched 0x2D CORRECTLY with the same latch — because its byte was
ready one cycle earlier. So SOF and token complete at DIFFERENT effective cycles
relative to bit_cnt. => NO fixed bit_cnt compare (7, next==8, or ==8) latches BOTH
classes correctly. Confirmed empirically: bit_cnt_next==8 gives ep_out=89 + rare
0x2D; bit_cnt==8 gives 0xA5 but kills 0x2D + ep_out=0. Oscillates.

TRUE ROOT CAUSE: recv_pid has NO reliable "byte assembled" signal. The completion is
guessed from bit_cnt, but the actual settle-cycle varies (entry seed set bit_cnt=1
and pre-loaded bit0, desyncing bit_cnt from the true bit position for some packets).

PROPER FIX (redesign, not a latch flip): make recv_pid entry NOT pre-shift/seed —
enter with bit_cnt=0 and byte_shift=0, shift ALL 8 bits inside recv_pid uniformly,
complete when bit_cnt==8 reading registered byte_shift. Then EVERY PID completes at
the identical cycle. The entry-seed hack (added for an earlier SOF fix) is the thing
desyncing the completion. Remove it + unify the shift, then re-measure clean-room.

STATUS: reverted to last-measured-good (bit_cnt_next==8, ep_out=89). Stopped editing
to avoid thrashing (flipped latch 3x, each fixing one PID class breaking another).

### TWO-PACKET DUMP — TRUE root cause: VARIABLE assembly-start delay per packet.

Side-by-side bit_cnt trajectory of 3 packets (completion latch is NOT the lever):
  pkt1: bcnt 1..8 = 0x1 0x2 0x5 0xA 0x14 0x29 0x52 0xA5  <- starts at bcnt=1, CLEAN
  pkt3: bcnt 1..8 = 0x0 0x0 0x1 0x2 0x4 0x8 0x10 0x21    <- byte_shift STAYS 0 for
        first 2 bcnt, then climbs -> assembly starts 2 bits LATE -> only 6 real bits
        by bcnt=8 (0x21, garbage).
  pkt2: byte_shift all 0x0, last_pid=0xA5 throughout = STALE register (no real latch).

TRUE ROOT CAUSE: recv_pid begins shifting at a VARYING offset relative to the true
first PID bit. Some packets (pkt1) enter aligned; others (pkt3) enter 1-2 bits early,
so the leading shifts capture 0s and the real PID is truncated/phase-shifted by
bcnt=8. This is why decodes SCATTER and why no fixed-bit_cnt completion works — the
misalignment is at ENTRY, and it's not constant.

WHY: idle->recv_pid trigger is `phy_rx_valid and phy_rx_active`. phy_rx_active goes
high at SYNC end, but the FIRST rx_valid after entry may not be the first PID bit —
depending on sample-phase alignment between when active asserts and the next
sample_en. For some packets there's a 1-2 cycle sl(leading 0s shifted).

PROPER FIX DIRECTION: gate recv_pid entry/first-shift on the SAME sample_en edge that
the PHY uses to emit the first PID bit — i.e. enter recv_pid only on the first
rx_valid where the PID actually starts, not on active+valid which can lead by 1-2
sample phases. Likely: PHY should signal "first PID bit" (a one-cycle start strobe at
:active entry) and SIE keys off THAT, instead of inferring from active&valid. The PHY
already resets dbg_rx_sym=0 at :active entry — a `rx_pid_start` strobe there is the
clean hook. Then every packet assembles from bit 0 uniformly.

STATUS: latch reverted to measured-good bit_cnt_next==8 (ep_out=89). Completion latch
confirmed NOT the bug. Next session: add PHY rx_pid_start strobe + SIE entry on it.

### rx_bit0 ALIGNMENT STROBE — BIG WIN. Token path now fully clean.

Added a PHY `rx_bit0` output: high on the rx_valid carrying PID bit 0 (PHY bit_cnt==0).
Wired PHY->top->SIE. SIE now enters recv_pid `on phy_rx_bit0` instead of
`phy_rx_valid and phy_rx_active`. This ALIGNS every packet to bit 0 uniformly,
eliminating the variable leading-zero offset (the scatter root cause).

VERIFIED via tmp_latch dump: with alignment, at completion (bit_cnt_next==8) the
REGISTERED byte_shift = full PID (0x2D), comb over-shifts to 0x5A. Latch registered
byte_shift (settled the comb-vs-reg question DEFINITIVELY, not by guessing).

RESULT (clean-room + ack oracles):
  tok_fail = {0 => ALL}  — ZERO crc5-fails, ZERO addr-mismatches (was 54802 fails!)
  crc5_at  = [0x0C] ONLY — perfect token residue every token (was 0x15/0x18/0x1C).
  ep_out   = 98.
=> The TOKEN datapath is now CORRECT. crc5 uniformly valid = tokens assemble right.

REMAINING BLOCKERS (2, both downstream of token->data classification):
 (1) token_is_setup_reg = 0 at every recv_data EOP. A stricter accept guard
     (rx_pid==0x2D/0x69/0xE1) does NOT help — dropping ep_out to 0 — meaning the
     rx_pid VALUE AT THE recv_token ACCEPT POINT (token_bits==15) is NOT 0x2D even
     though recv_pid assembled 0x2D and crc5 passed. => rx_pid is being overwritten
     between recv_pid completion and the token_bits==15 accept, OR the packet that
     reaches recv_token accept is a different (non-SETUP) token. NEXT: dump rx_pid
     across the recv_pid->recv_token transition for ONE accepted token.
 (2) crc16 never == 0xB001 at recv_data EOP -> no ACK. Likely downstream of (1):
     wrong token classification -> wrong data handling. Fix (1) first.

STATUS: reverted to crc5-clean state (ep_out=98, tok_fail=0, crc5=0x0C). The rx_bit0
strobe + registered-latch are KEPT (verified good). dev_state still 0. Enumeration
not complete, but the token path went from fully-broken to fully-clean this session.

### BLOCKER 1 ROOT CAUSE FOUND: recv_pid routing can't disambiguate SOF vs SETUP.

Accept-tracer + wide trace (directly observed, NOT sticky-wire): pkt3 assembled
rx_pid=0x2D at recv_pid completion, then went st=1 -> st=0 (IDLE), NOT st=3
(recv_token). So the SETUP token routes to idle and recv_token NEVER runs for it —
which is why token_is_setup=0 and (yesterday's) 55298 "accepts" were all a stale
dbg_accept artifact.

WHY: recv_pid routing test is `byte_shift[1]==1 and byte_shift[0]==0` (=bits 10) for
"token". But USB token PIDs end in 01, not 10 (SETUP 0x2D=..01, IN 0x69=..01,
OUT 0xE1=..01, SOF 0xA5=..01). So 0x2D fails the token test and falls to idle.

BUT flipping the test to ..01 REGRESSED crc5 (0x0C -> 0x15, 55034 fails) because SOF
(0xA5) ALSO ends in 01 and floods recv_token with heartbeats that fail addr/crc5.
=> PID class bits [1:0] CANNOT distinguish SOF from SETUP (both 01). Reverted.

PROPER FIX (needs care): route recv_pid on the FULL token PID set, and handle SOF
distinctly. Options:
  (a) route to recv_token when rx_pid in {0x2D,0x69,0xE1} (real device tokens),
      route SOF (0xA5) to idle/ignore, data (0xC3/0x4B) to recv_data.
  (b) keep going to recv_token for all 01-class but reject SOF at the accept
      (already partially done: `rx_pid != 0xA5`), AND ensure SOF's failed crc5
      doesn't count as a hard fail.
Option (a) is cleaner — explicit PID decode at completion using the (now-correct,
rx_bit0-aligned) rx_pid. NOTE: rx_pid IS reliable now (0x2D verified assembled).

CAUTION: dbg_route and dbg_accept are STICKY/registered — they contaminate frequency
oracles (read nonzero forever after first set). Trust per-packet dedup on dbg_pkt_num
and DIRECT rx_state transitions, not raw frequency of sticky debug wires.

STATUS: reverted to crc5-clean routing (old ..10 test). Bug identified: SOF/SETUP
share class bits. Next: implement option (a) — explicit rx_pid decode at recv_pid
completion.

### CRITICAL: STICKY DEBUG WIRES HAVE BEEN FALSIFYING THE JUDGES.

Definitive routing oracle (tmp_rt2, rx_state-transition based, NOT sticky wires):
  recv_pid -> recv_token transitions in WHOLE run: 1
  recv_pid -> recv_data  transitions: 1
  recv_token rows with dbg_crc5_at==0x0C: 0   <-- ZERO
=> The "crc5 = [0x0C]" and "tok_fail = {0 => all}" and "ep_out = 98" judges that
looked like WINS were STICKY-REGISTER ARTIFACTS. dbg_crc5_at latches 0x0C from one
early transient and reads it forever; tmp_cleanroom's frequency counts it every row.

REAL STATE: recv_pid essentially NEVER routes to recv_token (1 transition total).
The token path is effectively DEAD. Every "clean" judge this morning was a stuck
register, not real progress. The routing test [1]==1,[0]==0 sends almost nothing to
recv_token — which is why flipping it changed the (sticky) crc5 reading but the
underlying transition count stayed ~1.

PROCESS BUG (mine): I made+reverted ~6 edits based on sticky-wire judges. Multiple
dbg_* wires (dbg_route, dbg_accept, dbg_crc5_at, dbg_last_pid) are registered and
NEVER cleared, so any frequency/`distinct` oracle over them is meaningless.

MANDATORY NEXT STEP (measurement fix BEFORE any datapath edit):
  1. Rebuild judges to count rx_state TRANSITIONS (edges), not signal levels/freqs.
     Real metrics: #(idle->recv_pid), #(recv_pid->recv_token), #(recv_token->accept
     via a 1-cycle strobe), #(recv_data EOP with crc16 ok), dev_state edges.
  2. Make debug strobes ONE-CYCLE pulses (clear next cycle) OR only ever read them
     on the exact transition cycle, never by frequency.
  3. Re-establish the TRUE baseline: how many packets actually traverse
     idle->pid->token->accept end to end. Likely near zero.
Then, and only then, diagnose why recv_pid->recv_token almost never fires.

STATUS: tree at old routing (unchanged datapath). No real regression introduced (the
"progress" was illusory), but no real gain either. The genuine blocker is now known:
recv_pid routes to recv_token essentially never. Trust ONLY edge-based metrics next.

### EDGE ORACLE TRUTH TABLE — trustworthy, total visibility. TWO real bugs.

Per-packet assembled byte_shift at recv_pid completion (14 packets, edge-based):
  pkt1  0x52  [1:0]=10 -> TOKEN (garbage routed to token)
  pkt2  0x2D  [1:0]=01 -> REJECTED to idle  <-- REAL SETUP, WRONGLY REJECTED
  pkt3  0x00  -> reject      pkt4  0x04 -> reject   pkt5  0x30 -> reject
  pkt6..13 mostly 0x00 / 0x30 / 0x40 / 0x24 -> all reject (garbage)
  pkt14 0x03  [1:0]=11 -> data
Edge counts: idle->pid=14, pid->token=1, pid->data=1, pid->idle(reject)=12.
dev_addr changes=0 (never set). (dev_state accessor scope was wrong -> ignore its
count; dev_addr is the reliable enum signal and it is 0.)

TWO DISTINCT BUGS, now cleanly separated by trustworthy edges:
 BUG A (routing): pkt2 assembles 0x2D correctly but [1:0]==01 fails the token test
   ([1]==1,[0]==0 = 10). Real SETUP rejected. The token PID class is 01, not 10.
 BUG B (assembly): only 2/14 packets assemble a valid PID (pkt2=0x2D real, pkt14=0x03
   is DATA-ish). Pkts 3-13 assemble garbage (0x00/0x30/0x40...). rx_bit0 alignment
   fixed SOME packets but MOST still mis-assemble.

CORRECTION of prior false fears (all were sticky-wire illusions):
 - "flipping to 01 regresses crc5" = the crc5 reading was STICKY. Real transition
   counts are unaffected by the sticky level.
 - "SOF floods recv_token if routed on 01" = FALSE. NO packet assembles 0xA5 — the
   SOF heartbeats assemble as 0x00/0x52/garbage. There is no 0xA5 to flood.
 - "crc5=0x0C clean / ep_out=98 / tok_fail=0" = ALL sticky artifacts. Real state:
   1 token transition, 12 rejects.

PLAN (with trustworthy edge oracle as the ONLY judge):
 1. BUG A first (cheap): change routing to token on class bits 01 (the real token
    class). Re-measure pid->token edges — pkt2 (0x2D) should now route to token.
 2. BUG B: diagnose why pkts 3-13 assemble garbage though rx_bit0 aligned pkt2/14.
    Likely per-packet: some packets' rx_bit0 strobe mis-fires or the entry sample
    phase still varies. Use the edge oracle + per-packet byte trajectory.

### BUG B FIXED: rx_bit0 strobe was WRAPPING (fired ~4.5x/packet).

Edge oracle caught it: rx_bit0 pulsed 144x for 32 packets. Cause: rx_bit0 = rx_valid
and (bit_cnt==0), but PHY bit_cnt is a 3-BIT counter that WRAPS every 8 bits — so the
strobe fired at bits 0,8,16,... of each packet, re-entering recv_pid MID-PACKET and
scrambling assembly (the garbage 0x00/0x30/0x40 bytes; also the run-to-run variance).

FIX: added PHY `first_bit` flag — set 1 at :active entry, cleared after the first
non-stuffed data bit. rx_bit0 = rx_valid and first_bit. Now fires EXACTLY ONCE per
packet. VERIFIED: BIT0=32 pulses == ACTIVE=32 packets (was 144).

Edge oracle after fix: idle->recv_pid dropped 14->4 (mid-packet re-entries gone).
Bug A routing fix ([1:0]==01 token class) also in place.

NEW BLOCKER (next): only 4 of 32 rx_bit0 strobes cause an idle->recv_pid entry. The
SIE enters recv_pid `on phy_rx_bit0` ONLY when in idle; it's missing 28 strobes
because it's stuck in non-idle states (recv_token/recv_data not returning to idle
promptly, OR a prior packet left it hung). token_addr_match=0 still, dev_addr=0.

NEXT: with the edge oracle, trace SIE rx_state across several consecutive packets —
why isn't it back in idle for 28/32 strobes? Check recv_token/recv_data exit paths
and whether a hung state blocks re-entry. Metrics are now TRUSTWORTHY (edges + clean
strobe), so this should localize fast.

### BUG: recv_data STUCK forever (no EOP exit in its case arm). FIXED — big cascade.

State-return oracle: 28/32 rx_bit0 strobes hit while SIE in recv_data. recv_data ran
54301 cycles continuously (bit_cnt cycling 1..7,0.. endlessly), NEVER returning to
idle. Cause: the global `on phy_rx_se0 -> next :idle` EOP handler lives in a FIRST
block, but the MAIN `case rx_state` is a SECOND block. The recv_data arm implicitly
RETAINS rx_state and commits AFTER the EOP block, clobbering its `next :idle`. So
recv_data never exited; the SIE missed every subsequent packet strobe.

FIX: add explicit `on phy_rx_se0 do next :idle end` INSIDE the recv_data case arm.

CASCADE (edge oracle, trustworthy):
  idle->recv_pid : 4 -> 25
  recv_pid->token: 1 -> 14
  token_bits==15 : 1 -> 13   (tokens fully assemble now)
  recv_data->idle: 0 -> 4
The whole RX path came alive — 14 tokens route, 13 complete assembly.

NEXT BLOCKER (sharp): token_addr_match rising = 0. 13 tokens assemble but NONE pass
the accept (crc5==0x0C AND rx_addr==dev_addr). Tokens reach accept, get rejected.
Diagnose the accept: is crc5_next actually 0x0C at token_bits==15 (real, not sticky)?
is rx_addr correct? Build the accept-gate oracle keyed on the token_bits 14->15 edge.

MILESTONE: this is the biggest advance of the effort. RX FSM no longer hangs; tokens
flow and assemble. Only the token-accept gate + downstream ACK/enum remain.

### ACCEPT-GATE + PER-TOKEN THREE-TAP: PHY perfect, recv_pid latch off-by-one.

Per-token three-tap (clean rx_bit0 alignment) — PHY nrzi ground truth is PERFECT for
EVERY packet:
  pkt0 10100101=0xA5 SOF  pkt1 10110100=0x2D SETUP  pkt2 11000011=0xC3 DATA0
  pkt3 10010110=0x69 IN   pkt4 01001011=0xD2 ACK    (all correct, stuff=0 everywhere)
=> PHY + NRZI are FLAWLESS. Bug is 100% in recv_pid latch timing.

Per-bit dump (tmp_two) — SETUP assembles CORRECTLY then over-shifts:
  pkt2 (SETUP bits): bcnt6 byte_shift=0x2D (CORRECT) -> bcnt7 0x5A (0x2D<<1) -> latched 0x5A
  pkt1 (other):      bcnt7 byte_shift=0x52 -> latched 0x52
KEY: the byte is READY at a DIFFERENT bcnt per packet (SETUP ready at bcnt6, others
bcnt7). The latch fires at fixed bit_cnt_next==8 -> mis-latches whichever packet is
ready early. A FIXED bit_cnt compare CANNOT latch all packets (byte-ready bcnt varies).

WHY bcnt varies: entry pre-loads bit0 + bit_cnt=1, then recv_pid shifts. For some
packets bit_cnt and the true bit position diverge by 1 (likely a cycle where rx_valid
fires but the entry/first-shift overlaps). The pre-load is the desync source.

CLEAN FIX (designed, not yet applied — avoid thrashing the latch AGAIN):
Add a PHY strobe `rx_pid_done` = rx_valid and (bit_cnt==7)  [PHY bit_cnt counts real
data bits, wraps 0-7; ==7 is the 8th/last PID bit]. Wire PHY->top->SIE like rx_bit0.
SIE latches rx_pid + routes ON rx_pid_done, NOT on a bit_cnt compare. Deterministic,
packet-independent — same pattern that fixed entry alignment. This is the mirror of
rx_bit0 (start strobe) for the END of the PID.

MILESTONE STILL HOLDS: 25 idle->pid, 14 pid->token, 13 tokens assemble. RX flows.
Only this final latch-timing fix stands between us and correct PIDs -> accept -> ACK
-> enum. accept-gate oracle confirmed: crc5 never 0x0C ONLY because PIDs mis-latch
(garbage in -> garbage crc5). Fix the latch and the accept should pass.

### STROBE-ALIGNMENT ORACLE — rx_pid_done now clean (32x), comb is the PID.

Fixed rx_pid_done: was `rx_valid and bit_cnt==7` (bit_cnt WRAPS -> 112 pulses, hung
SIE). Now `rx_valid and dbg_rx_sym==7` (dbg_rx_sym doesn't wrap) -> EXACTLY 32 pulses.

Alignment at the pulse (rel=0), per packet:
  pkt  reg_bs  comb={bs[6:0],rxd}  true PID
  1    0x52    0xA5                SOF   (comb correct)
  3    0x61    0xC3                DATA0 (comb correct)
  5    0x25    0x4B                DATA1 (comb correct)
At rel=0: rx_valid=1, done=1, STILL in st=1 (recv_pid). So the SIE CAN latch here.
DECISION: latch the COMB value {byte_shift[6:0], phy_rx_data} on phy_rx_pid_done.
Registered byte_shift is 1 shift behind (wrong); comb is the fully assembled LSB PID.

CAVEAT: some packets' comb is bit-reversed (pkt2 0xB4=rev(0x2D), pkt4 0x96=rev(0x69))
— those SPECIFIC packets still mis-assemble upstream (separate from latch timing).
But SOF/DATA0/DATA1 assemble correctly, proving the comb-on-strobe latch is right.
The reversed subset is a residual per-packet assembly issue to chase AFTER the latch.

RE-APPLY (safe now — strobe verified clean 32x): SIE latch+route the comb PID on
`on phy_rx_pid_done` inside recv_pid. Previous attempt failed ONLY due to the 112x
wrap; that's fixed. Milestone (25/14/13) currently intact.

### rx_pid_done in SIE FSM HANGS it — signal-into-FSM issue, not latch logic.

Re-applied the strobe latch two ways (dual-on, and single-on with plain `if
phy_rx_pid_done`). BOTH hung the FSM: idle->recv_pid 25->1. Reverted to milestone
(25/14/13 restored, no loss).

KEY: the oracle can READ phy_rx_pid_done fine (32 clean pulses), but USING it in the
SIE recv_pid arm breaks ENTRY itself (which is `on phy_rx_bit0`, a DIFFERENT signal).
So merely referencing phy_rx_pid_done in the FSM destabilizes the whole state machine.
=> This is a SIGNAL-INTO-FSM problem (wiring / elaboration / comb path), NOT the
latch timing or the dual-on structure.

HYPOTHESES to test with an oracle (do NOT keep editing the latch):
 (a) phy_rx_pid_done isn't actually connected into the SIE -> reads constant/undef,
     poisoning the `next` mux. Check: does {[:sie],:phy_rx_pid_done} exist and toggle?
 (b) rx_pid_done = rx_valid and dbg_rx_sym==7 forms a comb path SIE reads that the
     elaborator mis-handles when it drives `next`.
 (c) both rx_bit0 (entry) and rx_pid_done reference overlapping PHY comb -> feedback.

NEXT ORACLE: capture phy_rx_pid_done BOTH from [:phy] and [:sie] scope in the SAME
run (milestone code, where SIE doesn't use it yet) — confirm it arrives at the SIE as
a real toggling per-cycle signal. If it's stuck/missing at [:sie], it's a wiring bug
(a). If present, the issue is (b)/(c) elaboration. THEN fix the identified cause.

MILESTONE INTACT: 25 idle->pid, 14 pid->token, 13 tokens assemble. Strobe proven
clean (32x). Only the "use strobe in SIE without hanging" mechanics remain.

### INLINE COMB-LATCH FIX (option b) — no new signal, no hang. Routing shifted.

Kept the working bit_cnt_next==8 completion; changed ONLY the latched value from
registered byte_shift to the COMB {byte_shift[6:0], phy_rx_data} (the strobe oracle's
correct-PID expression), and switched to value-based routing. Compiles, stable, NO
hang (avoided the phy_rx_pid_done-into-FSM problem entirely).

Edge oracle after fix:
  idle->recv_pid 25->32 (ALL packets now enter)
  recv_pid->data 4->12
  recv_pid->token 14->0   <-- tokens now route to DATA/reject, not token
Routing is value-based: ==0x2D/0x69/0xE1 -> token; ==0xC3/0x4B -> data; else idle.

DIAGNOSIS: data packets (DATA0 0xC3, DATA1 0x4B) now assemble+route CORRECTLY (12
data). But SETUP/IN route to 0 token -> they assemble BIT-REVERSED (0xB4=rev 0x2D,
0x96=rev 0x69), exactly the strobe-oracle caveat. So DATA0/DATA1 assemble correct
LSB-first, but SETUP/IN come out reversed. The reversal is PID-SPECIFIC / packet-
specific, NOT global (else DATA would reverse too).

=> Residual bug: a SUBSET of packets (tokens) bit-reverse while data packets don't.
Likely difference: token vs data PID bit patterns interact with a stuff/sample edge
case, OR the entry (rx_bit0) fires a cycle off for tokens specifically. NEXT ORACLE:
per-packet nrzi-vs-assembled for a SETUP and a DATA0 side by side to see WHERE the
token's bits reverse but the data's don't.

MILESTONE ADVANCED: 32 enter (was 25), 12 data route correctly. Latch mechanism now
correct + stable. Only the token-subset reversal remains before accept.

### REVCMP ORACLE — NOT reversal. Per-packet shift-count variance (again).

Trajectory column (ground truth; ignore the misaligned nrzi/gt cols):
  EP3: 0x1 0x2 0x4 0x9 0x12 0x25 0x4B -> latched 0xC3  (7 shifts, starts 0x1)
  EP5: 0x1 0x2 0x4 0x9 0x12 0x25 0x4B -> latched 0x4B  (IDENTICAL traj, diff latch!)
  EP4: 0x0 0x1 0x2 0x4 0x9 0x12 0x25  -> latched 0x96  (starts 0x0 = EXTRA leading shift)
  EP6: same as EP4.
KEY 1: EP3 and EP5 have IDENTICAL byte_shift trajectories but latch DIFFERENT PIDs
(0xC3 vs 0x4B). Impossible unless the comb latch reads phy_rx_data(bit7) at a
different cycle per packet -> the completion fires at inconsistent points.
KEY 2: EP4/EP6 trajectories start with an EXTRA 0x0 (one more shift than EP3/EP5).
So some packets get an extra leading shift -> bit_cnt and true bit position diverge
per packet -> bit_cnt_next==8 completion lands at different assembly points.

=> This is NOT a reversal bug. It's the SAME per-packet shift-count variance the
rx_pid_done strobe was designed to eliminate. Option (b) latch-comb fix happened to
align data packets but not tokens, because completion timing still varies per packet.

ROOT REMAINS: recv_pid completion must fire on a DETERMINISTIC per-packet marker (the
8th real bit), not bit_cnt_next==8 which desyncs when leading shifts vary. The clean
mechanism is the rx_pid_done strobe — BUT feeding it into the SIE FSM hangs it
(unresolved wiring/elab issue). So the two open threads are:
  (1) WHY do some packets get an extra leading 0x0 shift? (entry/rx_bit0 fires 1 early
      for those packets) — fixing THIS makes bit_cnt uniform and bit_cnt_next==8 works.
  (2) OR resolve the rx_pid_done-into-FSM hang to get a deterministic completion.
Thread (1) is likely cheaper: find why rx_bit0 leads by 1 for the extra-0x0 packets.

MILESTONE: 32 enter, 12 data route correct. Latch reads comb (correct mechanism).
Remaining: per-packet entry/shift-count variance (extra leading shift on a subset).

### CORRECTED: IT IS REVERSAL — but only for asymmetric PIDs. Entry timing is FINE.

Entry-timing oracle: the "extra 0x0" is NOT an extra shift — the packet's real first
bit IS 0 (nrzi=0 at the rx_bit0 cycle). byte_shift=0x0 is correct. Entry timing is
identical + correct for all packets. So the trajectories were never misaligned.

Clean-room per-packet decode (comb latch, 32 pkts):
  CORRECT: 0x4B DATA1 x7, 0xA5 SOF x5, 0xC3 DATA0 x4, 0xD2 ACK x2
  WRONG:   0x96 x8, 0xB4 x4, 0x87 x2
  0x96 = rev(0x69 IN) ; 0xB4 = rev(0x2D SETUP) ; 0x87 = rev(0xE1 OUT)
=> The THREE TOKEN PIDs (IN/SETUP/OUT) all come out BIT-REVERSED. Data/SOF/ACK decode
correctly. It IS a reversal bug, masked because the CORRECT-decoding PIDs happen to be
bit-palindromes or symmetric (0xA5=10100101 palindrome; 0xC3=11000011 palindrome),
so LSB vs MSB gives the same byte for THEM. The asymmetric PIDs (the tokens) reveal it.

This is the SAME LSB/MSB assembly-order issue diagnosed long ago (the brute-force
sweep found LSB-first), now cleanly isolated: the assembly is producing the WRONG
endianness, but only asymmetric PIDs expose it. 0xC3 & 0xA5 palindromes hid it again.

NEXT: this should be a definitive check, not a guess. The comb latch is
{byte_shift[6:0], phy_rx_data} (bit7=newest in MSB). If that's MSB-first but USB is
LSB-first, tokens reverse. FIX CANDIDATE: latch rev8 of the comb, OR change the shift
direction. VERIFY with clean-room: all of 0x2D/0x69/0xE1 must appear (not their revs).
Do NOT guess direction — test rev8(latched) against the true PID set in an oracle
FIRST, then apply.

MILESTONE: 32 enter, latch stable, 13/32 decode to correct PIDs. Only the token-class
reversal (endianness on asymmetric PIDs) remains before accept.

### ENDIANNESS FIX APPLIED — TOKEN ACCEPT + ACK FIRE FOR THE FIRST TIME.

rev8-check proved uniform rev8 -> 32/32 valid PIDs. Applied: latch the bit-reversed
comb {phy_rx_data, bs[0],bs[1],...,bs[6]} (inline in conditions since rx_pid is
registered/old-value). Result — TWO never-before-seen edges:
  token_addr_match rising: 0 -> 1   (a token PASSED accept: crc5 0x0C + addr match!)
  send_handshake rising:   0 -> 1   (an ACK 0xD2 was ARMED!)
  ep_out_valid rising: 9
The full token -> crc5 -> accept -> ACK chain fired end-to-end for the FIRST time.
The reversal was the last decode bug; PIDs are now correct.

NEW BLOCKER (exposed by success): idle->recv_pid dropped 32 -> 4. The SIE gets STUCK
after the first successful transaction (recv_token or the ACK/handshake path doesn't
return to idle cleanly — same class as the recv_data-stuck bug fixed earlier). So
only the FIRST transaction completes, then the FSM hangs, missing later packets.
dev_addr still 0 (enum needs the SET_ADDRESS transaction to complete + more).

NEXT: state-return oracle again — after the ACK arms, what state is the SIE in when
subsequent rx_bit0 strobes fire? Find the missing return-to-idle in recv_token /
handshake-arm path. This is the LAST structural blocker: decode is correct, accept
works, ACK arms — just need the FSM to cycle through ALL transactions, not hang after
the first.

MILESTONE (huge): correct PID decode (endianness fixed), token accept works, ACK
arms. From here: fix post-ACK state return -> multiple transactions -> dev_addr=1 ->
enum.

### POST-ACK: not an SIE hang — PHY detects only 4 packets after device TX.

Corrected via edge oracle: after the endianness fix, everything is CLEAN at rest post-
packet (phy_rx_state=0, tx_state=0, send_handshake=0). No hang. The eop0 tx_act escape
is in (harmless, keep). BUT the PHY only sees 4 rx_active rises (idx 624034,624302,
624570,625095) then the bus goes quiet for 54k cycles.

The host `enumerate` schedule statically drives the FULL sequence (GET_DESCRIPTOR
SETUP + IN*3 + OUT status, then SET_ADDRESS SETUP at line 317, then more) — ~30+
packets. But the PHY only DETECTS 4: SOF, SETUP, and 2 more (the first transaction).
TX_starts=1 = the device transmitted its first ACK.

HYPOTHESIS: the device's first TX/ACK drives the shared bus and leaves the line in a
state where the PHY can't detect the NEXT SYNC — so all packets after the device's
first transmission are missed. i.e. RX/TX bus-turnaround or line-state handoff bug.
The 4 detected packets are exactly those BEFORE the device first transmits.

WHAT'S CORRECT NOW (huge): endianness fixed -> PIDs decode right -> token accepted
(addr_match=1) -> ACK armed (send_handshake=1) -> ep_out fires. ONE full correct
transaction. Decode + accept + ACK-arm chain all verified by edges.

NEXT ORACLE: examine the bus line-state (dp/dn, tx_en, rx line) across the device's
first TX and the FOLLOWING host packet. Does the PHY see SYNC after TX? Is tx_en /
bus-turnaround leaving the line wrong? Find why RX detection dies after device TX.
This is the LAST blocker: get the PHY to keep detecting packets through TX turnaround,
then all ~30 packets process -> SET_ADDRESS completes -> dev_addr=1 -> ENUM.

### TURNAROUND ORACLE — ROOT CAUSE: device TX never ends (tx_act stuck high).

Bus-turnaround oracle nailed it:
  device first TX (tx_act rise) at idx 625197
  device TX ends (tx_act fall): nil   <-- NEVER FALLS
Line-state: at TX start rx_state->0, tx_en=1 tx_act=1, and tx_act stays 1 FOREVER.
=> The device starts transmitting the ACK and the TX FSM NEVER returns to idle, so
tx_act (=tx_state!=0) is stuck high. ALL PHY RX EOP exits are gated on bnot(tx_act),
so RX is permanently blocked -> only the 4 packets BEFORE the first device TX are seen.
This is the true root of "only 4 packets / dev_addr=0".

TX FSM (fs_phy) is structurally complete: idle->data->eop1->eop2->eop3->idle. But it
hangs in :data — :data only advances on tx_valid or tx_se0 per tx_bit_en. For a
HANDSHAKE (ACK = PID only, NO data payload), the SIE must drive tx_se0 right after the
8 PID bits to push :data->:eop1. If the SIE's handshake handoff never asserts tx_se0
(or tx_valid drops without tx_se0), :data waits forever -> tx_act stuck.

=> LAST BUG: SIE handshake TX path doesn't terminate the PID with tx_se0/EOP, so the
PHY TX FSM never completes. Fix: ensure the SIE drives tx_se0 (EOP) after sending the
handshake PID's 8 bits. Then TX completes -> tx_act falls -> RX resumes -> all ~30
packets process -> SET_ADDRESS -> dev_addr=1 -> ENUM.

STATE: decode correct, token accept works, ACK arms, ONE txn completes. Only the TX
handshake EOP-termination remains. This is the final blocker.

### TX DEADLOCK — both TX FSMs frozen at state 1 together (mutual handshake stall).

tmp_txstuck dump: from the cycle phy_tx_state->1, BOTH stay locked forever:
  phy_tx_state=1 (:data)  AND  sie_tx_state=1 (:tx_sync)  , phy_tx_en=1, ~54k cycles.
Neither advances. This is a MUTUAL two-FSM deadlock, not a missing single exit.

Chain:
- SIE :tx_sync advances `on phy_tx_ready`.
- phy_tx_ready = tx_act and tx_bit_en and (phy_tx_state==1). tx_act=1, state==1 hold,
  so it hinges on tx_bit_en = (phase==0). If phase isn't advancing / tx_bit_en never
  pulses at the right time, phy_tx_ready never asserts -> SIE :tx_sync never advances
  -> SIE keeps tx_sending=1 (tx_valid=1) -> PHY :data keeps hitting <<0,1,x>> cases
  (nrzi_toggle, NO exit) forever -> PHY never leaves :data.
- My <<0,0,_>> :data->:eop1 fix CANNOT fire because tx_valid is STILL 1 (SIE stuck in
  :tx_sync, not idle). So the fix is correct-but-unreached; the stall is upstream in
  the SIE<->PHY tx_ready handshake.

ROOT: the SIE :tx_sync <-> PHY tx_ready handshake never completes the first bit. Need
to check: does phy_tx_ready EVER pulse? Is `phase`/tx_bit_en advancing during TX? Is
the SIE reading the RIGHT ready signal? Likely tx_bit_en timing or a ready-signal
polarity/phase mismatch between the two clocked FSMs.

NEXT ORACLE: capture phase / tx_bit_en / phy_tx_ready during the stuck region. If
phy_tx_ready never pulses -> fix its gating (or SIE's wait). If it DOES pulse but SIE
misses it -> SIE :tx_sync guard timing. This is THE deadlock; everything else (decode,
accept, ACK-arm, RX) is proven. Fix this one handshake -> TX completes -> RX resumes
-> enum.

### NOT A DEADLOCK — corrected. PHY TX misses the brief EOP handoff (coarse sampling).

IR check: phy_phase is a clean unconditional Reg (enable=nil) advancing every clock;
tx_bit_en pulses every 4th cycle; tx_ready pulses correctly (12502 pulses). NOT frozen.
Ready-pulse dump: sie_tx_bit_cnt climbs 0..7 on ready pulses, then sie_tx_state
advances 1->2 (tx_sync->tx_pid). SIE TX is WORKING.

SIE_TX_SEQ = [0,1,2,5,0]  — SIE transmits handshake and returns to idle CORRECTLY.
PHY_TX_SEQ = [0,1]        — PHY TX enters :data and NEVER leaves (54231 cycles).

So the "mutual deadlock" was WRONG (I over-read a mid-TX snapshot). Real bug: the SIE
completes and passes through :tx_eop (state 5) driving phy_tx_se0=1 for only a FEW
cycles, then goes idle (tx_valid=0). But the PHY :data samples tx_se0/tx_valid ONLY
`on tx_bit_en` (every 4th cycle). The SIE's brief state-5 EOP pulse falls BETWEEN the
PHY's tx_bit_en sample points -> PHY misses both the <<1,_,_>> (se0) AND the <<0,0,_>>
(idle) transitions -> :data loops forever. My <<0,0,_>> fix is correct but the PHY
never SAMPLES the tx_valid=0 moment either (tx_valid drops and the SIE... actually
phy_tx_valid=tx_sending stays consistent, so the miss is the SE0 pulse being too short
for the 4-cycle sampling).

FIX CANDIDATES (verify with oracle, don't guess):
 (a) Make phy_tx_se0 STICKY/latched in the SIE until the PHY acknowledges (like
     send_handshake/tx_hs_ack), so the PHY catches it on the next tx_bit_en.
 (b) Hold SIE :tx_eop until phy_tx_ready (so SE0 spans a full PHY bit period) — the
     SIE :tx_eop already waits `on phy_tx_ready, next: :idle`, so check WHY state 5 is
     brief: does it see ready immediately and leave before the PHY samples se0?
 (c) PHY :data also samples tx_se0 combinationally (not only on tx_bit_en).
NEXT ORACLE: dump the exact cycles sie_tx_state==5 vs phy tx_bit_en — confirm the SE0
pulse misses the sample window. Then apply the aligned fix.

EVERYTHING ELSE PROVEN: decode, endianness, accept, CRC5, ACK-arm, SIE TX. Only this
PHY-samples-EOP timing remains.

### AST/IR BUG FIXED: `next` inside nested hdl_case was silently dropped.

User's instinct (consult AST/IR) was right. The EOP oracle showed the PHY DID sample
tx_se0=1 at a tx_bit_en cycle in :data (rel=3) but never transitioned — so it wasn't a
sampling miss. Root cause: fsm.ex parse_fsm_statement had clauses for :next/:on/:if but
NONE for a NESTED :case/:hdl_case. The PHY TX :data state's
`hdl_case <<tx_se0,tx_valid,tx_data>>` fell through to the PLAIN parser, so every
`next :eop1` inside it was DROPPED (no transition arc). Same class as the old
next-in-if bug.

TWO-SIDED FIX:
 1. fsm.ex: added parse_fsm_statement clause for nested {:case/:hdl_case, subject,
    clauses} — parses the bit-vector subject via Binary.parse_case_subject, patterns
    via Binary.parse_case_pattern, and BODIES via parse_fsm_statements (FSM-aware, so
    `next` becomes a real arc). New helper parse_fsm_data_clause.
 2. elaborate.ex: added convert_fsm_stmt clause for %{type: :case} that recurses into
    each clause body via convert_fsm_body, so {:state, atom} from a nested-case `next`
    is converted to its numeric const (fixed "Cannot elaborate expression:
    {:state, :eop1}").

RESULT (edge oracle):
  idle->recv_pid : 4 -> 32   (ALL packets flow; TX no longer blocks RX)
  send_handshake : 1 -> 4    (multiple ACKs; TX completes AND repeats)
  recv_pid->token: 14 ; token_bits->15: 14 ; token_addr_match: 1
The PHY TX FSM now leaves :data -> EOP -> releases tx_act -> RX resumes for all pkts.

REMAINING: dev_addr still 0. Structural blocks all cleared. Now a control-transfer
logic issue: the SET_ADDRESS SETUP+DATA+status must actually latch dev_addr=1 in the
CDC/SIE. That's downstream logic, not a wedge. NEXT: trace the SET_ADDRESS transaction
end-to-end (SETUP 0x2D + DATA0 [00 05 01...] + IN status ACK) and find where dev_addr
should be written.

### DATA PATH endianness fixed; now a BYTE-FRAMING off-by-one in recv_data.

SET_ADDRESS trace: SETUPs arrive (ep_out_setup rising=2) but addr_pending stays 0 —
the request was never parsed because the DATA payload reached the CDC as GARBAGE.
Root: recv_data assembled ep_out_data = {byte_shift[6:0], phy_rx_data} (MSB-first) —
the PID got the rev8 endianness fix but the DATA PATH was MISSED.

Applied rev8 to ep_out_data (bit-reverse like recv_pid). RESULT — bytes now DECODE:
  before: 0x60 0x00 0x80 0x00 0x00 0x48 ...  (garbage)
  after:  0x06 0x00 0x01 0x00 0x00 0x12 ...  (0x06=GET_DESC bRequest, 0x12=wLength 18!)
  and later: 0x05 0x01 ... (0x05 = SET_ADDRESS bRequest appears!)
So bit-order is now CORRECT (real request bytes 0x06, 0x12, 0x05 present).

REMAINING: bytes are shifted by ~1 byte position — byte 0 (0x80 bmRequestType) is
missing/wrong; the stream is framed one byte off. Same CLASS as the recv_pid
completion off-by-one, but for the DATA byte boundary: recv_data completes on
`bit_cnt == 7` (OLD value) and latches ep_out_data on that cycle. The first byte's
framing is off by one — likely the first data byte is dropped or bit_cnt starts
mis-aligned when entering recv_data from recv_pid.

NEXT: byte-framing oracle on recv_data — dump each ep_out_valid pulse's byte vs the
expected SETUP payload, and the bit_cnt trajectory at recv_data entry. Fix the
first-byte alignment (recv_data likely needs the same comb-latch / entry-bit handling
recv_pid got). Then request parses -> addr_pending -> dev_addr=1 -> ENUM.

PROGRESS: bit-order correct end-to-end (PID + data). Only recv_data BYTE framing
off-by-one remains between us and a parsed SET_ADDRESS.

### DATA PAYLOAD FULLY CORRECT — byte framing fixed. CDC parse is next.

Framing oracle: recv_data was entering with bit_cnt=8 (inherited recv_pid's final
count), so the first payload byte was mis-framed -> whole stream shifted 1 byte.
FIX: reset bit_cnt=0 at recv_pid's next:recv_data AND next:recv_token transitions.
RESULT: byte framing PERFECT — bit_cnt now 0,0,0,0,1,1,1,1,2... and ep_out bytes =
  0x80 0x06 0x00 0x01 0x00 0x00 0x12 0x00  == expected GET_DESCRIPTOR SETUP payload!
Data path is now fully correct: bit-order (rev8) + byte-framing (bit_cnt reset).

BUT addr_pending still 0 — SET_ADDRESS not parsed despite correct bytes. The payload
reaches the CDC correctly now (GET_DESC decodes byte-perfect), so the remaining issue
is in the CDC REQUEST PARSER: it must see the SET_ADDRESS SETUP (bmRequestType=0x00,
bRequest=0x05 -> match <<0x00,0x05>> at cdc_serial.ex:391) and set addr_pending.

NEXT: CDC-parse oracle. Does the CDC receive the SET_ADDRESS SETUP bytes into its
request-decode? Check: ep_out_setup pulses for the SET_ADDRESS SETUP, the bytes the
CDC's parser sees, and whether the <<0x00,0x05>> match fires. Likely the CDC's
byte-collection / setup-request FSM (cdc_serial.ex ~line 360-400) needs the same
attention, OR ep_out_setup isn't marking the right packet. Everything upstream
(decode/accept/ACK/TX/data-framing) is now PROVEN correct end-to-end.

MILESTONE: full USB data path decodes correctly. Only CDC control-request parsing
remains before dev_addr=1.

### CDC never dispatches SETUP — ep_out_pkt_end gated on CRC16 that never validates.

CDC-parse oracle: SETUP completions (ep_out_pkt_end & setup) = 0. The CDC's dispatch
(if ep_out_pkt_end do ... hdl_case <<req_type,req_code>>) NEVER runs, so addr_pending
stays 0. But setup_cnt reaches 0..7 (bytes ARE received). So the block is skipped
because ep_out_pkt_end never pulses.

SIE sets ep_out_pkt_end at recv_data EOP ONLY if bxor(rx_crc16_reg,0xB001)==0
(cdc/sie.ex:318). CRC16 oracle: at all 6 data-packet EOPs, crc16=0x5800 CONSTANT,
bxor(0xB001)=0xE801 -> NEVER valid (0/6). Deterministic wrong value = systematic
CRC16 computation/feed error, NOT corruption.

Same CLASS as the CRC5 story. Data BYTES now decode correctly (0x80 0x06 00 01...),
but CRC16 residue is wrong. Suspects (verify with oracle, like the CRC5-feed oracle):
 - crc16 feed bit order / timing vs the (now byte-rev8'd) data path.
 - crc16 seed: recv_pid sets rx_crc16_reg=0xFFFF at route->data; is it applied at the
   right cycle relative to the first data bit?
 - is crc16 fed during recv_data every rx_valid (rx_crc16_reg=crc16_next)? off-by-one
   like the byte framing was?
 - USB CRC16 is over data bits in TX order (LSB-first); the byte-rev8 fix might have
   desynced what the CRC sees vs what ep_out_data latches.

NEXT: CRC16-feed oracle — per data bit, capture crc16_bit_in, rx_crc16_reg pre/post,
and cross-check vs a reference CRC16 over the known SET_ADDRESS payload
(00 05 01 00 00 00 00 00). Find whether feed order or seed timing is wrong. Fix ->
residue 0xB001 -> ep_out_pkt_end -> SETUP dispatched -> addr_pending -> dev_addr=1.

MILESTONE: data bytes decode perfectly. Last blocker = CRC16 residue (mirror of the
CRC5 fix) so the SIE releases ep_out_pkt_end to the CDC.

### CRC16 HARDWARE EXONERATED — fed the WRONG BIT SPAN (feed/framing misalignment).

CRC16-feed oracle: hw crc16_next == ref CRC16.next on EVERY bit. Seed 0xFFFF correct.
ref CRC16.compute over fed bits = 0x5800 == hw final 0x5800. So the HW faithfully
CRCs its input — the INPUT bit span is wrong.

SMOKING GUN — bit count: fed 81 bits. But the data is 8 SETUP bytes (64 data bits) +
16 CRC bits = 80, or the ep_out delivered 10 bytes (0x80 06 00 01 00 00 12 00 E0 F4)
= 80 data bits + 16 = 96. Neither is 81. The CRC16 is fed a MISALIGNED span:
 - ep_out shows 10 bytes: the last two (0xE0 0xF4) are the CRC16 bytes being delivered
   as DATA (they should be consumed by CRC, not passed to the CDC).
 - fed bits = 81: off from any clean 8*k boundary.
=> The CRC16 feed and the (now-fixed) byte-framing DISAGREE on packet boundaries. The
CRC is fed a bit stream that starts/ends off by the same class of off-by-one we fixed
for byte framing — OR recv_data doesn't distinguish DATA bytes from the trailing CRC16
bytes, feeding CRC over the wrong window AND passing CRC bytes to ep_out.

NEXT: align the CRC16 feed window to the data-byte framing. Likely recv_data must:
 (a) feed crc16 the same bits it frames into bytes (currently crc16_bit_in=phy_rx_data
     raw, but recv_data entry reset bit_cnt=0 for byte framing — the CRC feed may not
     honor the same start), and
 (b) know the packet length so the last 2 bytes are CRC (checked) not data (delivered).
Actually USB doesn't send length in-band; the DEVICE knows via the SETUP wLength /
the EOP. So the fix is: CRC16 runs over ALL received bits incl the 16 CRC bits, and
residue==0xB001 confirms; ep_out should deliver data bytes but the LAST 2 (CRC) are
naturally excluded because EOP ends the packet. The 81-bit count says the feed
STARTED one bit early/late vs framing. Pin the exact start offset (oracle: first
crc16-fed bit vs first byte-framed bit) and align.

MILESTONE: CRC16 HW proven correct. Last blocker = align CRC16 feed span to the
data-byte framing so residue lands 0xB001 -> ep_out_pkt_end -> dev_addr=1.

### CRC16 REACHES 0xB001 THEN ONE EXTRA BIT CORRUPTS IT — off-by-one at packet END.

Alignment oracle, packet tail (idx):
  624924: crc16_reg = 0xB001   <-- CORRECT RESIDUE! CRC validated here.
  624925: rx_valid = 1          <-- ONE EXTRA bit fed (the 81st)
  624926: crc16_reg = 0x5800   <-- extra bit corrupts residue
  ...
  624930: rx_state -> 0 (EOP). The bxor(rx_crc16_reg,0xB001)==0 check at phy_rx_se0
          runs NOW, sees 0x5800 (already corrupted), so ep_out_pkt_end NEVER fires.

So the CRC16 is CORRECT — it hits 0xB001 at the true end of the 80 data+CRC bits. But
recv_data feeds ONE MORE rx_valid bit (81 total) AFTER the residue is valid, clobbering
it to 0x5800 before the EOP check samples it.

ROOT: an extra rx_valid pulse at packet end (the 81st bit). Likely the USB EOP
(SE0 SE0 J) — the trailing J or an SE0-boundary sample is being counted as a data bit
by rx_valid, feeding CRC one time too many. OR the PHY emits one spurious rx_valid as
it transitions to EOP.

FIX OPTIONS (verify): 
 (a) PHY: don't assert rx_valid on the EOP/SE0 boundary sample (gate rx_valid off when
     entering EOP), so exactly 80 bits are fed.
 (b) SIE: check crc16 residue == 0xB001 the cycle BEFORE the extra bit (latch a
     "crc_was_valid" flag when residue hits 0xB001, use it at EOP).
(a) is cleaner (fixes the bit count at source). NEXT: check the PHY rx_valid at the
EOP boundary — is it pulsing one extra time as rx_state goes active->eop? Gate it.

MILESTONE: CRC16 VALIDATES (0xB001 reached!). Only a 1-bit over-feed at packet end
hides it from the EOP check. Fix the extra rx_valid -> residue holds 0xB001 ->
ep_out_pkt_end -> SETUP dispatch -> dev_addr=1 -> ENUM.

### CRC16 FIXED (6/6 valid!) — now a FRAMEWORK bug: ep_out_pkt_end never commits.

rx_valid EOP-gate fix (bnot(sym_se0)) worked: CRC16 residue now holds 0xB001, 6/6
valid at data EOP. Huge — the CRC path is DONE.

But addr_pending STILL 0. Traced to: sie ep_out_pkt_end NEVER = 1 (PKTEND=0) even
though the EOP handler runs (send_handshake fires 8x). The EOP `if` block:
  if rx_state==2 and match and (setup or out) and crc_ok do
    arm_handshake(0xD2)      # -> send_handshake=1  WORKS (8x)
    ep_out_pkt_end = 1       # NEVER commits (0x)
    ep_out_setup   = token_is_setup_reg
  end
Condition VERIFIED satisfied: data EOPs show match=1 setup=1 crc_ok=true (rows 1 & 3).
So the block executes and the guard holds, yet ep_out_pkt_end (an OUTPUT PORT) doesn't
get its =1, while send_handshake (a WIRE, via arm_handshake) in the SAME block does.

=> FRAMEWORK BUG: an OUTPUT-PORT assignment inside a nested `on phy_rx_se0` within the
FSM `defaults` block does not commit its value in signal reduction (the defaults-level
default and/or output-port handling clobbers it), whereas plain wires commit fine.
Same FAMILY as the next-in-hdl_case AST bug — an FSM elaboration gap, now for output
assignment inside nested-on-inside-defaults.

TRIED: conditional-clear (if bnot(phy_rx_se0) do ep_out_pkt_end=0 end) — did NOT fix.
So it's not just the blanket default; the nested-on `=1` itself isn't winning.

NEXT (framework): inspect how ep_out_pkt_end's mux is built vs send_handshake's.
Likely the `on phy_rx_se0` block (inside defaults) contributes to send_handshake's
reduction but ep_out_pkt_end's output-port mux takes the defaults value. Fix in the
elaborator (sequential/signal reduction) OR restructure: set ep_out_pkt_end via a
plain wire in the EOP block, then drive the OUTPUT from that wire in comb — mirroring
how send_handshake works (wire) vs a directly-assigned output.

STATUS: ENTIRE USB datapath PROVEN correct end-to-end (decode, PID, accept, CRC5, ACK,
TX, data bytes, CRC16 6/6 valid). The ONLY remaining blocker is this one framework
signal-reduction bug preventing the ep_out_pkt_end pulse from reaching the CDC.
Fix it -> SETUP dispatch -> addr_pending -> dev_addr=1 -> ENUM. Workaround likely:
route ep_out_pkt_end through an intermediate wire like send_handshake.

### IR-CONFIRMED framework bug: `on`-block assignment in FSM `defaults` is DROPPED.

IR comparison (tmp_ir_cmp): send_handshake = a real Reg (mux driver, survives).
pkt_end_pulse = DOES NOT EXIST in the elaborated design at all — eliminated. Its only
assignment is inside `on phy_rx_se0` within the FSM `defaults` block, and the
elaborator does NOT register that as a driver, so the wire is dead-code-eliminated.

=> ROOT (framework, IR-proven): an assignment inside an `on <edge>` block that sits
inside the FSM `defaults` block is not recognized as driving the signal. send_handshake
only *appeared* to work because it has OTHER drivers/readers (TX FSM, defaults clear)
so it can't be eliminated AND its value comes from those — the on-block `=1` there may
ALSO be getting dropped (needs check), but it commits via arm_handshake being read
widely. ep_out_pkt_end (and my pkt_end_pulse) have no other driver -> dropped -> pulse
never reaches the CDC.

Tried & failed (all consistent with this): direct output assign, wire+comb, defhw
call, remove default. NONE work because the on-in-defaults assignment itself isn't a
recognized driver.

REAL FIX (two options):
 (a) FRAMEWORK: fix the FSM elaborator to treat assignments inside `on <edge>` blocks
     within `defaults` as drivers (register them in the signal reduction). This also
     future-proofs the DSL. Same spirit as the next-in-hdl_case fix.
 (b) WORKAROUND: move the EOP ep_out_pkt_end logic OUT of the on-phy_rx_se0-in-defaults
     block into the MAIN `case rx_state` recv_data arm — detect EOP there (on
     phy_rx_se0 inside :recv_data, which we ALREADY added for the state exit) and set
     ep_out_pkt_end/setup/ep in that arm, where assignments ARE honored (proven: the
     recv_data EOP exit `next :idle` works).
(b) is faster and low-risk — the recv_data arm's `on phy_rx_se0` already works for the
state exit, so add the ep_out_pkt_end pulse THERE.

STATUS: entire USB datapath PROVEN (decode/PID/accept/CRC5/ACK/TX/data/CRC16 6/6).
The ONLY blocker is this elaboration bug dropping the EOP pulse. Fix (b): emit
ep_out_pkt_end from the recv_data arm's existing working on-phy_rx_se0 -> CDC dispatch
-> dev_addr=1 -> ENUM.

### WORKAROUND WORKED — SET_ADDRESS PARSED (addr_pending=1)! Now IN-status stage.

Moved ep_out_pkt_end emission from the (broken) on-phy_rx_se0-in-defaults into the
recv_data case arm's on-phy_rx_se0 (assignments there commit). RESULT:
  addr_pending rising: 1  (was 0) — the CDC DISPATCHED the SETUP, matched <<0x00,0x05>>,
  set addr_pending=1, pending_addr=0x01. THE SET_ADDRESS REQUEST IS PARSED.
Framework bug confirmed + worked around (recorded: on-in-defaults assigns are dropped;
future framework fix should register them). Cleaned up dead pulse wires/defhw.

NEXT LINK: dev_addr still 0 because dev_addr=pending_addr fires on ep_in_done (host
ACKs the CDC's ZLP STATUS IN). ep_in_done rising: 0 — the IN STATUS stage isn't
completing. Chain: CDC send_zlp_status() -> device transmits ZLP DATA1 on IN token ->
host sends ACK -> SIE sees ACK (0xD2) -> ep_in_done -> apply addr.

So the device must now RESPOND to an IN token with a ZLP DATA1, and the host's ACK
must register as ep_in_done. This exercises the TX DATA path (device->host) + the
host-ACK detection (sie.ex:305 `rx_state==1 and assembled==0xD2 -> ep_in_done`).
NEXT ORACLE: trace the IN status transaction — does the device send the ZLP, does the
host ACK, does ep_in_done fire? Likely the device-IN-response or ACK-detect needs
attention. Then dev_addr=1 -> dev_state=1 -> ... -> ENUM.

MILESTONE: request parsing WORKS end-to-end. dev_addr one IN-status-ACK away.

### FRAMEWORK ELABORATION BUG confirmed 3x — output-port assign in nested block dropped.

The SAME root cause has now bitten THREE times, each a different facet:
 1. SIE ep_out_pkt_end: assign inside on-phy_rx_se0-in-defaults -> DROPPED. Worked
    around by emitting from the recv_data case arm instead.
 2. CDC ep_in_loaded (defhw call in nested hdl_case): send_zlp_status() set ep0_state
    (committed) but ep_in_loaded (committed? NO). Inlined -> still dropped.
 3. CDC ep_in_loaded (comb override): drove `if ep0_state==2 do ep_in_loaded=1`.
    ep0_state==2 holds 52252 cycles but ep_in_loaded stays 0 — the comb override is
    IGNORED because the signal ALSO has registered (FSM) drivers; the elaborator picks
    the registered driver (stuck 0 via the nested-block bug), not the comb.

ROOT (framework, not USB): assigning an OUTPUT PORT (or any signal) inside a nested
construct (hdl_case / on / if) within an FSM or on-clk body is not reliably registered
as a driver. Internal wires with wide readership survive; output ports and
single-driver wires get dropped or lose to a conflicting registered driver.

This is the ELABORATOR HARDENING gap (the real Amaranth delta). Per-signal workarounds
are whack-a-mole (3 tried, partial). PROPER FIX is in the elaborator:
 - sequential/signal reduction must collect assignments from ALL nested blocks
   (hdl_case clauses, on-edge blocks, nested ifs) inside FSM/on-clk bodies as drivers,
   same as it does for top-level statements. Mirror the next-in-hdl_case fix but for
   VALUE assignments, and resolve output-port multi-driver (comb vs seq) coherently.

STATUS: USB is ONE protocol stage from dev_addr=1. Decode/accept/CRC5/CRC16/TX/data/
SET_ADDRESS-parse ALL PROVEN. The only blocker is this framework bug preventing the
CDC from asserting ep_in_loaded to send the ZLP STATUS. Fixing the elaborator here
finishes USB AND hardens the DSL (the credibility work vs Amaranth).

NEXT: fix the elaborator's nested-block assignment collection (sequential.ex signal
reduction). Then ep_in_loaded commits -> device sends ZLP -> host ACK -> ep_in_done ->
dev_addr=1 -> dev_state -> ENUM.

### ELABORATOR ROOT CAUSE ISOLATED: nested-clause assign doesn't reach signal mux.

Corrected earlier theories:
 - NOT a double-driver: the "2 Regs" were sie_ep_in_loaded (real) + a diag counter
   (substring match). Only ONE real register.
 - NOT a top wiring bug: ep_in_loaded is correctly wired CDC-out -> sie_ep_in_loaded
   wire -> SIE-in. One driver, correct direction.

CONFIRMED root: the register sie_ep_in_loaded's driver mux does NOT contain a
reachable `const 1` from the CDC SET_ADDRESS clause's `ep_in_loaded = 1`. The mux
tree (walked partially) shows MUX -> case value Const 0 / default -> deeper mux, but
the nested `if ep_out_pkt_end do ... if ep_out_ep==0 and ep_out_setup do
hdl_case <<req_type,req_code>> do <<0x00,0x05>> -> ep_in_loaded=1 ...` assignment is
NOT contributing an arm. Meanwhile ep0_state=2 (same clause) DID commit — ep0_state is
assigned in MANY clauses (start_descriptor, ep_in_done handler...) so it has other mux
arms; ep_in_loaded's only meaningful set is in this deep clause, and it's lost.

So: build_mux_from_statements (sequential.ex:119) is not building a mux arm for an
assignment that lives inside if -> if -> hdl_case(binary patterns) nesting, at least
for a signal whose ONLY assignment is that deep. find_all_assigned DOES collect it
(handles :if/:case), so the signal gets a Reg — but build_mux_from_statements's
recursion through the same nesting drops the arm (produces the hold/default value).

Likely culprit: the :case handler in build_mux_from_statements (line 172) with
binary_pattern clauses, when nested inside :if branches — the mat_val/baseline
threading or build_case_mux may not carry the clause's assignment out. Same FAMILY as
next-in-hdl_case (which was the PARSE side); this is the VALUE-BUILD side.

NEXT (surgical): build a MINIMAL repro — tiny `on :clk do if a do hdl_case <<x>> do
<<1>> -> sig=1 end end end` and assert sig's Reg mux has a const-1 arm. Then fix
build_mux_from_statements (or build_case_mux) to emit the arm. This finishes USB
(ep_in_loaded commits -> ZLP -> ep_in_done -> dev_addr=1) AND fixes the DSL for all
deeply-nested clause assignments — the core Amaranth-parity elaborator hardening.

STATUS: USB fully decoded + SET_ADDRESS parsed; blocked ONLY by this elaborator
mux-build gap. This is compiler-internals work deserving a focused pass.

### CORRECTION: elaborator is FINE. Real bug = CDC ep0_state stuck at 2 (logic).

MAJOR correction of the last several turns: the "framework drops nested assignments"
theory was WRONG.
 - Minimal repro (if->if->hdl_case binary-pattern, direct assign AND defhw call)
   ALL produce a correct const-1 mux arm. Elaborator handles the CDC's construct fine.
 - Mux-reachability walk (with a VISITED set — the earlier hang was my walker lacking
   memoization on a shared DAG, NOT a design issue): Const 1 IS reachable in the
   sie_ep_in_loaded mux. The assignment is correctly in the netlist.
So ep_in_loaded's =1 EXISTS; its enabling CONDITION just isn't producing a live pulse.

REAL ROOT (CDC logic, cycle dump at addr_pending rise idx 627175):
  ep0_state is ALREADY == 2 two cycles BEFORE this SET_ADDRESS dispatches, and stays
  2 through +4. => ep0_state entered the ZLP-status-ready state in a PRIOR transaction
  and NEVER returned to 0/idle. The CDC is WEDGED in the status stage.
  ep_out_pkt_end=1 & ep_out_setup=1 at the dispatch cycle (rel0), addr_pending rises
  rel1 — so the SETUP DID dispatch. But ep0_state stuck at 2 means the IN-status
  handshake can't cleanly complete -> ep_in_done never fires -> dev_addr never applied.

NOTE: ep_in_loaded column printed nil in this dump (capture issue) — reconfirm whether
ep_in_loaded is ever high given ep0_state is pinned at 2 (my earlier comb-drive from
ep0_state==2 should have held it high; the conflict needs a clean re-measure).

NEXT (CDC state machine, NOT elaborator): find why ep0_state never leaves 2. It should
go 2 -> (send ZLP, host ACKs, ep_in_done) -> 0. Likely the ep_in_done handler
(cdc:298) that would reset ep0_state / clear_ep_in never fires because the device's
ZLP IN never actually transmits+gets ACKed. Trace ep0_state transitions across the
whole run: does it EVER return to 0 after first reaching 2? Fix the status-stage
completion. Elaborator work is NOT needed — revert any exploratory elaborator pokes.

STATUS: USB decode + SET_ADDRESS dispatch PROVEN. Blocker = CDC status-stage state
machine wedged at ep0_state=2. Ordinary logic bug. Clean up the false-lead comb
override + pulse wires already removed.

### PRECISE STATE — CDC IN-data path: ep_in_loaded/valid never assert (near-cornered).

Trustworthy facts (re-verified this pass):
 - Elaborator is CORRECT. Repro passes; const-1 reachable in sie_ep_in_loaded mux.
 - ep0_state sequence = [0,1,2], then STUCK at 2 forever (53590 cyc). Never returns 0.
 - ep_in_loaded / ep_in_valid: 0 rising, 0 high cycles — NEVER assert, in any state.
 - ep_in_ready rising = 19 (SIE asks for IN data; CDC never provides).
 - start_descriptor (GET_DESC) RAN: it committed ep0_state=1 AND desc_remain=18. But
   its ep_in_loaded=1 / ep_in_valid=1 (same defhw, same cycle) did NOT hold high.

Mux structure of sie_ep_in_loaded (top arms):
  sel=ep_out_pkt_end -> (sel=_land_285797 -> CONST 1)      [SET_ADDRESS inline set]
  default -> sel=ep_out_valid -> ... -> sel=ep_in_done -> _case / default=hold.
The SET_ADDRESS ep_in_loaded=1 IS in the mux behind ep_out_pkt_end (a 1-cyc pulse) —
should pulse high once at dispatch; but measured 0 high cycles. start_descriptor's
ep_in_loaded=1 is NOT visible as a reachable top CONST-1 (lost, while ep0_state=1 from
the same call survived). This is the unresolved contradiction.

HYPOTHESIS (unconfirmed): program-order reduction — a LATER branch in the CDC else-body
(e.g. the line-324 descriptor-stream block's else `ep_in_valid=0`, or an implicit
hold/default) overrides the earlier start_descriptor set within the same cycle's
reduction, for the OUTPUT ports specifically. ep0_state/desc_remain escape because
they aren't reassigned later in the body; ep_in_loaded/valid ARE touched later (line
324, 328/332) so the later (false-path-derived) value wins.

CLEANEST FIX DIRECTION (next session, fresh): restructure the CDC so ep_in_loaded /
ep_in_valid are driven from a SINGLE authoritative place (comb from ep0_state, with NO
other assignments), eliminating the multi-site program-order fight. e.g.
  comb: ep_in_loaded = (ep0_state==1 or ep0_state==2)
        ep_in_valid  = (ep0_state==1 and desc_remain>0)
and remove all the scattered ep_in_loaded/valid=... in the defhws/clauses. This makes
the IN-data offer a pure function of state — robust, and sidesteps the reduction fight.
(A prior comb-override attempt failed because scattered REGISTERED assigns still fought
it; the fix must REMOVE those, not add a competing driver.)

STATUS: USB decode + SET_ADDRESS dispatch PROVEN end-to-end. Elaborator PROVEN fine.
Remaining: ONE CDC restructure so the IN-data-offer signals assert. That yields ZLP ->
ep_in_done -> dev_addr=1 -> dev_state -> ENUM. Deferred to a fresh session (long run;
error rate rising). Clean handoff.

### SESSION TOTAL: FOUR genuine bugs FIXED & verified:
1. PHY rx_valid per-byte→per-bit ✓   2. PHY rx_data stale→decoded ✓
3. FSM elaborator drops next-in-if ✓  4. SIE drops first PID bit at idle→recv_pid ✓
From "nothing decodes" to: every packet decodes at the wire, SOF PID assembles &
classifies, CRC5 validates. Remaining: SETUP/DATA0 per-packet alignment + address
match. The AST inspection (concat IR + sequential read-order) was the key to
locating bug #4 correctly after two mis-located attempts.

### SESSION TOTAL: FOUR genuine bugs, THREE fixed & verified.
1. PHY rx_valid per-byte→per-bit (FIXED ✓)   2. PHY rx_data stale→decoded (FIXED ✓)
3. FSM elaborator drops `next` in `if` (FIXED ✓ — state now reaches 3)
4. Token acceptance gate chain (CRC5 / rx_pid persistence) — FRONTIER, not yet
   resolved.
Receive datapath fully repaired; every packet decodes; FSM transitions work; the
remaining work is SIE token-acceptance protocol logic. All findings
measurement-verified. Instrumentation was the decisive enabler throughout.
Each was a real narrowing. The verified, surviving facts: PHY rx_active/rx_valid
correct; SIE FSM (entry, bit-count, classification, exit) all correct; the bug is
purely that **wrong bit VALUES arrive at the SIE** — an NRZI encode/decode fault
in the host↔PHY wire round-trip. That is the last unprosecuted branch and where
the next session must start. The tooling (snapshot + per-cycle stride) is what
made every kill deterministic rather than speculative.

## Methodological note (important)

Four successive theories were floated and overturned tonight, each looking
certain from a partial view: (1) rx_active stale-state bug, (2) rx_valid never
fires, (3) SIE stuck in recv_pid never completing PID, (4) PID misclassified.
ALL were wrong — caught by insisting on one more measurement before editing code.
The lesson: aggregate numbers (max/dist) suggest mechanism but do not prove it;
only the per-cycle transition table + the exact conjunction that gates a
transition proves it. Verify the precise gating condition on the precise cycles
before asserting any root cause.

## Tooling delivered along the way

- `enumerate_trace mode: :snapshot` — dense fold, captures combinational signals.
- `enumerate_trace stride: :cycle` — per-cycle snapshot, resolves sub-bit combs.
Both are the durable payoff: the diagnosis above is impossible without them, and
they are what repeatedly exposed the premature conclusions.

### RESOLVED: dev_addr=1 achieved. Root cause = ACK-detect endianness (NOT a CDC wedge).

MAJOR CORRECTION of the prior handoff. Two things were wrong in the previous diagnosis,
both traced to a SINGLE measurement artifact:

1. WRONG-SIGNAL-KEY READING ARTIFACT (the thing that sent the last session down the
   "CDC IN-data-offer never asserts / needs comb restructure" rabbit hole).
   The oracles read ep_in_loaded/ep_in_valid as `sie.(x,:ep_in_loaded)` =
   Map.get(values, {[:sie], :ep_in_loaded}). But the ACTUAL trace key is
   {[:cdc], :sie_ep_in_loaded} — scope [:cdc], name literally :sie_ep_in_loaded (the
   CDC output port, flattened). So every read returned nil; nil==1 is false; the
   oracle reported "0 high cycles / never asserts." FALSE.
   With the correct accessor (match by bare-name suffix, scope-agnostic):
     sie_ep_in_loaded: rising=1 high=54497   sie_ep_in_valid: rising=1 high=907
     desc_remain streams 18 -> 0 cleanly.
   The CDC was offering IN data CORRECTLY THE WHOLE TIME. ep0_state reaching 2 and
   "sticking" was just the descriptor completing (desc_remain hit 0 -> ep0_state=2),
   NOT a wedge. NO CDC restructure was needed; the recommended comb-driver rewrite
   would have been a fix for a non-bug.

   LESSON (reinforced): before trusting ANY "signal X never asserts" oracle result,
   dump the actual value-map keys (x.values |> Map.keys()) and confirm the scope+name.
   Trace signal names flatten inconsistently: sie_rx_state -> {[:sie],:rx_state} but
   sie_ep_in_loaded -> {[:cdc],:sie_ep_in_loaded}. A scope-agnostic accessor
   (find first {{_,nm},v} where to_string(nm)==name) avoids the whole trap.

2. THE REAL BUG (one line): sie.ex ACK-detect compared the RAW byte_shift-order
   `assembled` against 0xD2. recv_pid classification was rev8-fixed long ago (rx_pid =
   reversed PID), but the ep_in_done ACK-detect at sie.ex:309 was MISSED by that fix
   and kept comparing the un-reversed value. A received ACK (0xD2 on the wire)
   accumulates into byte_shift as rev8(0xD2)=0x4B, so `assembled == 0xD2` was DEAD —
   ep_in_done never fired -> dev_addr never applied. Proven: rx_pid/dbg_pid_bits DO
   contain 0xD2 (ACK decoded correctly in reversed form); assembled/byte_shift never do.

   FIX: added comb wire `assembled_pid` = the same rev8 expression recv_pid uses
   ({phy_rx_data, byte_shift[0..0..6..6]}) and changed the ACK-detect to
   `assembled_pid == 0xD2`. Minimal, mirrors the existing endianness convention.

RESULT (verified, scope-agnostic accessor):
  ep_in_done: rising=6 high=6 (was 0)
  ep0_state seq: [0,1,2,0,2,0]  (was [0,1,2]-stuck; now cycles back to idle)
  dev_addr values: [0, 1]   dev_state: [0, 1]   pending_addr: [0, 1]
  => SET_ADDRESS COMPLETE. Enumeration's address stage works.

NEXT FRONTIER (separate bug, downstream): SET_CONFIGURATION does not advance
dev_state to 2. In the set_configuration phase window, ep_out_pkt_end=0 and ZERO
ep_out_data bytes reach the CDC — the SET_CONFIG SETUP token/data is not being
accepted at device address 1. get_descriptor_addr1 (also at addr 1) DID work, so it's
not a blanket addr-1 failure; likely a per-transaction accept/timing detail specific
to that SETUP. This is a NEW investigation, not the SET_ADDRESS bug.

### RESOLVED: full enumeration to CONFIGURED. Root cause = token addr/ep endianness.

CORRECTION to the note just above: get_descriptor_addr1 did NOT actually work either —
both it and set_configuration failed. Everything AFTER SET_ADDRESS was being dropped.

Root cause (one bit-order bug, same class as the ACK-detect fix): the recv_token
address/endpoint field assembly shifted LEFT ({rx_addr[5..0], phy_rx_data}) but USB
token fields are LSB-first, so it must shift RIGHT ({phy_rx_data, rx_addr[6..1]}). The
first-arrived bit (the LSB) was landing in the top position — rx_addr decoded as
rev7(actual). PROVEN by oracle: at devaddr=1 the received addr latched as 0x40 =
rev7(0x01) exactly; at devaddr=0 it latched 0x0 (= rev7(0)), which is why every stage
BEFORE SET_ADDRESS passed and the bug stayed invisible until dev_addr went nonzero.
Fixed both rx_addr (7-bit) and rx_ep (4-bit) to shift right.

PROCESS NOTE (cost me a full detour): while bisecting I round-tripped edits through a
scratch /tmp copy + stage/commit, and a stale base silently reverted the assembled_pid
ACK fix — so a run showed a 'regression' that was actually my own clobber, not the
address change. The address right-shift was correct all along. Also ruled out an
elaborator/AST cause first: a minimal repro proved {bit, sig[6..1]} and {sig[5..0], bit}
elaborate to IDENTICAL correct 7-bit concat->mux IR — the shift-concat is structurally
sound. LESSON: edit the real file in place (filesystem MCP), don't bisect through a
scratch copy that another tool may touch.

RESULT (verified): ep_in_done rising=4; addr_pending rising=1; dev_addr [0,1];
dev_state [0,1,2] (reaches CONFIGURED); ep0_state cycles [0,1,2,0,2,0,1,2,0,2,0]
instead of wedging. Full sim enumeration: GET_DESCRIPTOR -> SET_ADDRESS -> GET_DESC@1
-> SET_CONFIGURATION -> configured.

TWO bugs closed this session, both endianness: (1) ACK-detect compared raw byte_shift
instead of the rev8 PID; (2) token addr/ep assembled MSB-first instead of LSB-first.
The rev8/LSB-first convention now holds uniformly across PID, data payload, ACK-detect,
and token fields.
