defmodule Hw.CDC.PulseSync do
  @moduledoc """
  Toggle-based pulse synchronizer for single-cycle events crossing clock
  domain boundaries.

  ## Why not Sync2 for pulses?

  `Hw.CDC.Sync2` is safe for **level** signals — signals that hold their
  value long enough for the destination clock to sample them reliably.
  A single-cycle pulse in a fast source domain (e.g. 180 MHz, 5.5 ns)
  may be far narrower than one period of the slow destination clock
  (e.g. 48 MHz, 20.8 ns), so Sync2 will miss it most of the time.

  ## How this works

  The source domain converts each incoming pulse into a **toggle**:
  every pulse flips a single-bit register. The toggle is a level signal
  — it holds its new state indefinitely — so it crosses the domain
  boundary safely through a standard two-flop synchronizer. The
  destination domain detects rising/falling edges on the synchronized
  toggle and re-generates a one-cycle pulse.

  ```
  src_domain                         dst_domain
  ──────────                         ──────────

  pulse_in ──► [toggle_reg XOR]      [Sync2 ff0] ──► [Sync2 ff1]
                     │                                     │
                     └────────────────────────────────►[prev_ff]
                                                           │
                                                    (ff1 XOR prev) ──► pulse_out
  ```

  ## Constraints

  - The source pulse must not fire a second time before the destination
    has seen the first one. For most hardware events (USB packet done,
    interrupt, etc.) this is naturally satisfied — events are separated
    by many cycles. Do NOT use this for back-to-back pulses at the
    source clock rate.

  - There is a latency of 2–3 destination clock cycles from the source
    pulse to the output pulse.

  - Both source and destination must be synchronous clocks (derived from
    the same oscillator via PLL). Truly asynchronous clocks are fine too,
    but the metastability budget of Sync2 still applies.

  ## Usage

      # Safely cross ep_out_pkt_end from clk_fast (180 MHz) to clk_48 (48 MHz)
      instance :sync_pkt_end, Hw.CDC.PulseSync,
        clk_src: :clk_fast,
        clk_dst: :clk_48,
        rst_src: :rst,
        rst_dst: :rst,
        pulse_in:  :ep_out_pkt_end_fast,
        pulse_out: :ep_out_pkt_end_sync

  ## Ports

  - `clk_src`   — source clock domain
  - `clk_dst`   — destination clock domain
  - `rst_src`   — synchronous reset in source domain
  - `rst_dst`   — synchronous reset in destination domain
  - `pulse_in`  — single-cycle pulse in `clk_src` domain
  - `pulse_out` — single-cycle pulse in `clk_dst` domain (re-generated)
  """

  use Hw.Component

  clock :clk_src
  clock :clk_dst

  input  :rst_src,   1
  input  :rst_dst,   1
  input  :pulse_in,  1
  output :pulse_out, 1

  # Source domain: toggle register
  wire :toggle,      1, init: 0

  # Destination domain: two-flop sync chain + edge detector
  wire :sync_ff0,    1, init: 0
  wire :sync_ff1,    1, init: 0
  wire :prev,        1, init: 0

  # Source domain: flip toggle on every incoming pulse
  on :clk_src do
    if rst_src do
      toggle = 0
    else
      if pulse_in do
        toggle = bnot(toggle)
      end
    end
  end

  # Destination domain: two-flop synchronizer on the toggle
  on :clk_dst do
    if rst_dst do
      sync_ff0 = 0
    else
      sync_ff0 = toggle
    end
  end

  on :clk_dst do
    if rst_dst do
      sync_ff1 = 0
    else
      sync_ff1 = sync_ff0
    end
  end

  # Destination domain: edge detector — XOR current vs previous
  on :clk_dst do
    if rst_dst do
      prev = 0
    else
      prev = sync_ff1
    end
  end

  comb do
    pulse_out = bxor(sync_ff1, prev)
  end
end
