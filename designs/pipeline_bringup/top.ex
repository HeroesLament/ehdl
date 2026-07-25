defmodule PipelineBringup.Top do
  @moduledoc """
  `pipeline` macro bring-up — silicon sign-off for the feed-forward pipeline sugar.

  Standalone (no USB, no MCP2515, no ESP32): 25 MHz -> PLL -> 48 MHz, a
  free-running counter drives a **4-stage `pipeline`** and, alongside it, a
  **hand-written reference** of exactly the same four stages with explicit
  widths and explicit skew registers. On-chip logic compares the two every
  cycle the pipeline claims `valid`, and separately checks that `valid` itself
  arrives at exactly the pipeline depth. Both verdicts are sticky and are
  streamed out the US1 FTDI serial port by `Hw.Diag.SerialReport`.

  The point is that the board is the oracle. Nothing here is signed off by
  simulation: the design carries its own reference model in fabric, so a
  mismatch between the macro-generated pipeline and the hand-written one shows
  up as a latched bit on the wire.

  ## What is under test

      pipeline :dut, clock: :clk_48, reset: :rst, valid_in: :in_v, valid_out: :det_v do
        stage do p1 = x0 + x1 end
        stage do p2 = p1 >>> LOG2_N end
        stage do p3 = p2 * ALPHA end
        stage do p4 = p3 + gate end
      end

  Three properties of the feature are exercised at once:

    * **Inferred widths** — `p1..p4` are never declared; `:infer` sizes each one
      from its driver.
    * **Valid threading** — `det_v` is `in_v` delayed exactly 4, with only the
      valid chain reset.
    * **Auto-balance (anti-skew)** — `gate` is read in stage 4 (index 3), so the
      macro must generate `gate__dly_1..3` and retarget the reference. The
      hand-written model spells those three registers out by hand; if the macro
      picks the wrong depth, the outputs disagree.

  `LOG2_N` and `ALPHA` are UPPERCASE params. They parse as aliases, not vars,
  so auto-balance must leave them alone and they stay compile-time constants
  (`>>> LOG2_N` is a free shift, not a barrel shifter).

  ## Why the operands are zero-extended to 8 bits

  EHDL's `+` does not widen — `add` infers `max(width(a), width(b))`. If `x0`
  and `x1` were declared as bare 4-bit slices, `p1 = x0 + x1` would infer 4 bits
  and truncate mod 16, and the 8-bit reference model would disagree for a reason
  that has nothing to do with the pipeline macro. Zero-extending the three
  operands to 8 bits removes that: with `x0`, `x1`, `gate <= 15` we get
  `p1 <= 30`, `p2 <= 15`, `p3 <= 45`, `p4 <= 60`, so every intermediate is exact
  in *both* models regardless of which width `:infer` picks. A width difference
  between the two can then never manufacture a false mismatch — only a real
  behavioural difference in the generated pipeline can.

  ## Oracle (silicon only — no sim sign-off)

  US1 FTDI serial (`/dev/cu.usbserial-D01477` @ 9600), six bits per line:

      b0 = pll_locked      expect 1
      b1 = mismatch        expect 0   sticky: pipeline output != reference
      b2 = vbad            expect 0   sticky: valid asserted at the wrong cycle
      b3 = ran             expect 1   sticky: at least one comparison happened
      b4 = match_cnt[24]              heartbeat, toggles ~1.4 Hz
      b5 = match_cnt[25]              heartbeat, toggles ~0.7 Hz

  GREEN = `1001` on b0..b3 with b4/b5 visibly counting. A green board means the
  generated pipeline matched a hand-written pipeline bit-for-bit on every valid
  cycle, at the right latency, for as long as it has been powered.

  LEDs mirror the same verdict: led0 = pll_locked, led1 = det_v,
  led2 = mismatch, led3 = vbad, led7..4 = match_cnt[27..24].

  ## Latency check in detail

  `fill_cnt` saturates at 5 and reads `min(k, 5)` on cycle `k`, where `k = 0` is
  the first cycle after reset releases. `in_v` is registered to 1 at the end of
  cycle 0, so it is high from cycle 1, and a depth-4 pipeline must raise `det_v`
  on cycle 5 and never before. The invariant checked every cycle is therefore
  exactly `det_v == (fill_cnt == 5)`; a pipeline that is one stage short or one
  stage long latches `vbad`.

  ## Wiring

  Nothing external. Board USB (US1) for power, programming and the report
  serial. No GPIO header connections required.
  """

  use Hw.Component

  param :LOG2_N, default: 1
  param :ALPHA,  default: 3

  clock :clk_25mhz, freq: 25.0
  clock :clk_48, freq: 48.0, domain: :sys, reset: :rst, reset_style: :sync

  output :ftdi_rxd, 1
  output :led,      8

  # PLL / reset nets
  wire :pll_locked,  1
  wire :clk_48,      1   # PLL output net (also declared as a clock above)
  wire :_clk_unused, 1
  wire :rst,         1
  wire :zero1,       1
  wire :dummy_pu,    1
  wire :dummy_rc,    4

  # Stimulus: a free-running counter sliced into three small operands, each
  # zero-extended to 8 bits so the non-widening `+` never truncates (see the
  # moduledoc).
  wire :cnt,  8, init: 0
  wire :x0,   8
  wire :x1,   8
  wire :gate, 8

  # Pipeline valid handshake. `p1..p4` and `gate__dly_1..3` are NOT declared —
  # the macro generates them as `:infer` signals. Declaring them here would
  # defeat the point of the test.
  wire :in_v,  1, init: 0
  wire :det_v, 1, init: 0

  # Hand-written reference model of the same four stages, explicit 8-bit regs
  # and an explicit skew chain.
  wire :g1, 8, init: 0
  wire :g2, 8, init: 0
  wire :g3, 8, init: 0
  wire :g4, 8, init: 0
  wire :gate_d1, 8, init: 0
  wire :gate_d2, 8, init: 0
  wire :gate_d3, 8, init: 0

  # Verdicts
  wire :fill_cnt,   3, init: 0
  wire :vbad,       1, init: 0
  wire :mismatch,   1, init: 0
  wire :ran,        1, init: 0
  wire :match_cnt, 32, init: 0

  # SerialReport bits
  wire :rb0, 1
  wire :rb1, 1
  wire :rb2, 1
  wire :rb3, 1
  wire :rb4, 1
  wire :rb5, 1

  comb do
    zero1 = 0

    # Explicit zero-extension: a 4-bit slice concatenated under four zero bits.
    x0   = {0b0000[3..0], cnt[3..0]}
    x1   = {0b0000[3..0], cnt[7..4]}
    gate = {0b0000[3..0], cnt[5..2]}

    rb0 = pll_locked
    rb1 = mismatch
    rb2 = vbad
    rb3 = ran
    rb4 = match_cnt[24..24]
    rb5 = match_cnt[25..25]

    led = {match_cnt[27..24], vbad, mismatch, det_v, pll_locked}
  end

  instance :pll, ULX3S.PLL,
    CLKOP_DIV:    9,
    CLKOS_DIV:    2,
    CLKOP_CPHASE: 8,
    CLKOS_CPHASE: 1,
    clk_in:    :clk_25mhz,
    clk_out0:  :clk_48,
    clk_out1:  :_clk_unused,
    locked:    :pll_locked,
    phase_dir: 0,
    phase_step: 0

  instance :reset_gen, Hw.ReEnum,
    HOLD_CYCLES:  2_400_000,
    clk:          :clk_48,
    pll_locked:   :pll_locked,
    btn:          :zero1,
    cmd_pulse:    :zero1,
    rst:          :rst,
    pu_drop:      :dummy_pu,
    reenum_count: :dummy_rc

  instance :report, Hw.Diag.SerialReport,
    BYTE_CYCLES: 60_000,   # one 9600-baud frame @48MHz
    clk: :clk_48,
    rst: :rst,
    b0:  :rb0,
    b1:  :rb1,
    b2:  :rb2,
    b3:  :rb3,
    b4:  :rb4,
    b5:  :rb5,
    txd: :ftdi_rxd

  # --- The device under test -------------------------------------------------
  pipeline :dut, clock: :clk_48, reset: :rst, valid_in: :in_v, valid_out: :det_v do
    stage do p1 = x0 + x1 end
    stage do p2 = p1 >>> LOG2_N end
    stage do p3 = p2 * ALPHA end
    stage do p4 = p3 + gate end
  end

  # --- Stimulus, reference model and on-chip checkers ------------------------
  on :clk_48 do
    # Free-running stimulus. Unconditional, like the pipeline's data registers,
    # so both models see identical operands on identical cycles.
    cnt = cnt + 1

    # Reference model: same four stages, hand-written, plus the skew chain the
    # macro is supposed to generate for `gate`.
    g1 = x0 + x1
    g2 = g1 >>> LOG2_N
    g3 = g2 * ALPHA
    g4 = g3 + gate_d3

    gate_d1 = gate
    gate_d2 = gate_d1
    gate_d3 = gate_d2

    if rst do
      in_v      = 0
      fill_cnt  = 0
      vbad      = 0
      mismatch  = 0
      ran       = 0
      match_cnt = 0
    else
      in_v = 1

      if fill_cnt < 5 do
        fill_cnt = fill_cnt + 1
      end

      # Latency oracle: det_v == (fill_cnt == 5), every cycle.
      if det_v == 1 do
        if fill_cnt < 5 do
          vbad = 1
        end
      end

      if det_v == 0 do
        if fill_cnt == 5 do
          vbad = 1
        end
      end

      # Data oracle: on every valid cycle the pipeline output must equal the
      # hand-written reference.
      if det_v do
        ran = 1

        if p4 == g4 do
          match_cnt = match_cnt + 1
        else
          mismatch = 1
        end
      end
    end
  end
end
