defmodule Hw.ReEnum do
  @moduledoc """
  Self-contained USB re-enumeration reset generator.

  This component OWNS reset generation for a USB FS device. It replaces the
  separate `Hw.ResetSync` + re-enum-trigger split (whose ResetSync `rst_in`
  re-arm indirection was hard to reason about) with a single hold counter that
  drives BOTH the whole-design reset and the D+ pullup drop.

  ## What it does

  A USB host only re-runs enumeration when it sees the device disconnect and
  reconnect. On this board the D+ pullup (`usb_fpga_pu_dp`) signals "device
  present", so a re-enumeration means: drop the pullup long enough for the host
  to notice (>2.5 us), then raise it again while the whole design is held in
  reset, so a clean device greets the fresh enumeration.

  Two situations assert reset + drop pullup:

    1. **Power-on**: once `pll_locked` rises, hold `rst` for `HOLD_CYCLES` so the
       PLL/logic settle before releasing. (This is the classic ResetSync job.)
    2. **Re-enumeration**: a trigger (`btn` level, or a `cmd_pulse` strobe)
       restarts the hold from zero, re-dropping the pullup and re-asserting reset
       for another full `HOLD_CYCLES`.

  Outputs:

    * `rst`     — active-high synchronous reset for the whole design. High during
                  the power-on hold and during any re-enum window; low once a
                  hold completes.
    * `pu_drop` — high during a re-enum window (NOT during the initial power-on
                  hold): forces the D+ pullup low so the host sees an unplug. The
                  top level drives `usb_fpga_pu_dp = phy_pu and not pu_drop`.

  ## reset_style: :none

  This component GENERATES reset, so it cannot be gated by the reset it produces.
  `clock :clk, reset_style: :none` emits a bare `always @(posedge clk)` block;
  initial state comes from `init:` values on the wires.

  ## Design

  A single `hold_cnt` counts up while `holding`. Reaching `HOLD_CYCLES - 1`
  clears `holding` (reset releases). A trigger, or `pll_locked` going low,
  restarts the hold. `armed` remembers that PLL lock has been seen at least once
  so we don't release reset before the PLL is up. `reenum` distinguishes a
  re-enum window (pullup drop) from the initial power-on hold.

  ## Usage

      instance :reset_gen, Hw.ReEnum,
        HOLD_CYCLES: 2_400_000,          # ~50 ms @ 48 MHz
        clk:        :clk_48,
        pll_locked: :pll_locked,
        btn:        :btn1_level,
        cmd_pulse:  :us1_cmd_reset,
        rst:        :rst,
        pu_drop:    :reenum_pu_drop

      # usb_fpga_pu_dp = phy_pu and not reenum_pu_drop
  """

  use Hw.Component

  # Hold length for reset assertion / the disconnect window, in clk cycles. Must
  # comfortably exceed the host disconnect-detect time (~2.5 us = 120 cycles
  # @48 MHz); default ~50 ms so the host hub state machine unambiguously sees an
  # unplug and a clean power-on settle.
  param :HOLD_CYCLES, default: 2_400_000

  clock :clk, reset_style: :none
  input  :pll_locked, 1
  input  :btn,        1
  input  :cmd_pulse,  1

  output :rst,     1
  output :pu_drop, 1

  # Reset-SURVIVABLE observation of re-enum activity. Because this component is
  # reset_style: :none, this counter is NOT cleared by the `rst` it generates —
  # so it can definitively record that a re-enum window actually opened, which a
  # gauge in the reset-gated top-level block structurally cannot (that block is
  # frozen while rst is high, i.e. during the very window it would observe).
  # Saturating 4-bit count of re-enum windows STARTED (0..15).
  output :reenum_count, 4, init: 0

  # 24 bits covers HOLD_CYCLES up to ~16.7M cycles (~350 ms @48 MHz).
  wire :hold_cnt, 24, init: 0
  wire :holding,   1, init: 1   # reset asserted while holding; start held at power-on
  wire :reenum,    1, init: 0   # this hold is a re-enum window (drop pullup) vs power-on

  # --- pll_locked synchronizer (2 FF) --------------------------------------
  # pll_locked is generated in the PLL and is ASYNCHRONOUS to clk. Feeding it
  # straight into the combinational `rst` meant the reset DE-ASSERTION edge was
  # unsynchronized: different flops across the SIE/CDC/PHY could sample the
  # release on different clock edges, leaving the USB stack in inconsistent
  # startup states that failed enumeration at a VARYING point (~30-40% pass,
  # silicon-observed: sometimes stuck at SET_ADDRESS, sometimes at the
  # post-address GET_DESCRIPTOR). Synchronize pll_locked through two FFs so the
  # reset release is always aligned to a clk edge and every register leaves
  # reset on the SAME cycle. This is the standard conservative-reset discipline:
  # async assert is fine, but de-assertion MUST be synchronized.
  wire :lock_s1,   1, init: 0   # first sync flop (may be metastable)
  wire :lock_s2,   1, init: 0   # second sync flop — clean, clk-aligned pll_locked
  wire :locked_d,  1, init: 0   # registered lock_s2, for its rising edge

  wire :trigger,   1
  wire :lock_rise, 1

  comb do
    # A re-enum trigger: button held, or a one-cycle command strobe.
    trigger = btn or cmd_pulse
    # PLL just locked (rising edge of the SYNCHRONIZED lock) — (re)start the hold.
    lock_rise = lock_s2 and bnot(locked_d)

    # Reset is asserted whenever we are holding. Also force reset while the
    # (synchronized) PLL lock is low — nothing runs without a stable clock. Using
    # lock_s2 (not the raw async pll_locked) keeps the reset-release edge clean.
    rst = holding or bnot(lock_s2)
    # Pullup drops during ANY reset hold — power-on AND re-enum — and while the PLL
    # is not yet locked. RATIONALE (silicon-proven intermittent-enum bug): the D+
    # pullup is what tells the host "a device is present, start enumerating". If it
    # is asserted while the USB stack is still held in reset (the ~50 ms power-on
    # hold), the host begins enumeration and sends its first SETUP into a DEAF
    # device — the PHY/SIE are in reset and never latch it (dashboard: GD0/LB00,
    # stuck at DEV1). Whether enumeration succeeded came down to whether the host's
    # first SETUP happened to land before or after the hold released (~30-40% pass).
    # Holding the pullup LOW until reset releases makes the device announce itself
    # only once it can actually listen, so the host always enumerates into a ready
    # device. (This is the standard USB bring-up ordering: come up disconnected,
    # settle, THEN connect.)
    pu_drop = holding or bnot(lock_s2)
  end

  on :clk do
    # 2-FF synchronizer for the async pll_locked. lock_s2 is the clean, clk-aligned
    # version everything else uses; locked_d tracks it for rising-edge detection.
    lock_s1  = pll_locked
    lock_s2  = lock_s1
    locked_d = lock_s2

    if trigger do
      # Start (or restart) a RE-ENUM hold: drop pullup + reset for HOLD_CYCLES.
      # Count a NEW window only on the trigger's rising edge into a non-reenum
      # state, so a held button (btn level asserted for many cycles) counts once,
      # not every cycle. Saturate at 15.
      if bnot(reenum) and reenum_count < 15 do
        reenum_count = reenum_count + 1
      end
      holding  = 1
      reenum   = 1
      hold_cnt = 0
    else
      if lock_rise do
        # PLL (re)locked: start a POWER-ON hold (reset only, no pullup drop).
        holding  = 1
        reenum   = 0
        hold_cnt = 0
      else
        if holding do
          if hold_cnt == HOLD_CYCLES - 1 do
            holding = 0
            reenum  = 0
          else
            hold_cnt = hold_cnt + 1
          end
        end
      end
    end
  end
end
