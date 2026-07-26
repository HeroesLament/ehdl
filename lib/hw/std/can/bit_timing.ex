defmodule Hw.CAN.BitTiming do
  @moduledoc """
  CAN bit-timing generator: time quanta, segment counters, and resynchronisation.

  This is the piece that turns a free-running clock into CAN's two strobes:

    * `sample_point` — one clock pulse at the end of Phase Segment 1. The bus
      value latched here is the received bit, exposed on `sampled_bit`.
    * `write_point` — one clock pulse at the end of Phase Segment 2, i.e. the
      bit boundary. A transmitter drives its next bit here.

  Deliberately factored out of the controller so a second instance can later
  serve a CAN FD data phase, which is the same machine with a second set of
  segment parameters and a mid-frame switch between them. Nothing here is
  classic-CAN-specific.

  ## Bit layout

  A bit time is `1 + PROP_SEG + PHASE_SEG1 + PHASE_SEG2` time quanta, indexed
  from 0:

      index 0                    Sync Segment (always 1 TQ)
      1 .. PROP_SEG              Propagation Segment
      .. + PHASE_SEG1            Phase Segment 1   -> sample point at its end
      .. + PHASE_SEG2            Phase Segment 2   -> write point at its end

  Sample point as a percentage is `(1 + PROP_SEG + PHASE_SEG1) / TQ_PER_BIT`.
  CiA recommends 87.5% at 500 kbit/s and below, 75% at 1 Mbit/s.

  ## Parameters

  - `TQ_CLOCKS`   - Clock cycles per time quantum (default 6)
  - `PROP_SEG`    - Propagation segment, in TQ (default 2)
  - `PHASE_SEG1`  - Phase segment 1, in TQ (default 3)
  - `PHASE_SEG2`  - Phase segment 2, in TQ (default 2)
  - `SJW`         - Resynchronisation jump width, in TQ (default 2)

  Bit rate is `CLK_FREQ / (TQ_CLOCKS * TQ_PER_BIT)`. The defaults give
  8 TQ x 6 clocks = 48 clocks per bit, which is **1 Mbit/s at 48 MHz** with a
  75% sample point. `config/2` computes parameter sets for other rates.

  ## Ports

  - `clk`, `rst`   - Clock and synchronous active-high reset
  - `rx`           - Bus value, already through a 2-FF synchroniser
  - `resync_en`    - Allow soft resynchronisation on recessive->dominant edges.
                     A transmitter holds this low so it does not resync on its
                     own edges.
  - `hard_sync`    - One-cycle pulse: restart the bit time immediately. Used on
                     the falling edge that starts a frame while the bus is idle.
  - `sample_point` - One-cycle pulse at the end of Phase Segment 1
  - `write_point`  - One-cycle pulse at the bit boundary
  - `sampled_bit`  - Bus value latched at the last sample point

  ## Resynchronisation

  On a recessive-to-dominant edge with `resync_en` high, the phase error is the
  distance from the Sync Segment. A late edge (before the sample point)
  lengthens Phase Segment 1; an early edge (after it) shortens Phase Segment 2.
  Either adjustment is clamped to `SJW`, and shortening never pulls the bit end
  earlier than the sample point.
  """

  use Hw.Component

  param :TQ_CLOCKS,  default: 6
  param :PROP_SEG,   default: 2
  param :PHASE_SEG1, default: 3
  param :PHASE_SEG2, default: 2
  param :SJW,        default: 2

  clock :clk, freq: 48.0
  input  :rst,          1
  input  :rx,           1
  input  :resync_en,    1
  input  :hard_sync,    1
  output :sample_point, 1
  output :write_point,  1
  output :sampled_bit,  1

  # Clock counter within the current time quantum.
  wire :clk_ctr, 12, init: 0
  # Time-quantum index within the current bit.
  wire :tq_ctr,   8, init: 0
  # Segment boundaries for the bit in progress. Reloaded to nominal each bit,
  # adjusted in place by resynchronisation.
  wire :seg1_end, 8, init: 5
  wire :bit_end,  8, init: 7

  wire :rx_d,     1, init: 1
  wire :sampled,  1, init: 1
  wire :sp_reg,   1, init: 0
  wire :wp_reg,   1, init: 0

  wire :nom_seg1_end, 8
  wire :nom_bit_end,  8
  wire :tq_tick,      1
  wire :rx_fall,      1
  wire :e_early,      8
  wire :adj_late,     8
  wire :adj_early,    8
  wire :shortened,    8

  comb do
    # Nominal boundaries, from the segment parameters.
    nom_seg1_end = PROP_SEG + PHASE_SEG1
    nom_bit_end  = PROP_SEG + PHASE_SEG1 + PHASE_SEG2

    tq_tick = (clk_ctr == TQ_CLOCKS - 1)

    # CAN resynchronises only on recessive (1) -> dominant (0) edges.
    rx_fall = rx_d and not rx

    # Late edge: phase error is simply the TQ index. Early edge: the distance
    # remaining to the bit boundary.
    e_early = bit_end - tq_ctr + 1

    adj_late  = if tq_ctr  > SJW, do: SJW, else: tq_ctr
    adj_early = if e_early > SJW, do: SJW, else: e_early
    shortened = bit_end - adj_early

    sample_point = sp_reg
    write_point  = wp_reg
    sampled_bit  = sampled
  end

  on :clk do
    if rst do
      clk_ctr  = 0
      tq_ctr   = 0
      seg1_end = nom_seg1_end
      bit_end  = nom_bit_end
      rx_d     = 1
      sampled  = 1
      sp_reg   = 0
      wp_reg   = 0
    else
      rx_d   = rx
      sp_reg = 0
      wp_reg = 0

      if hard_sync do
        # Restart the bit time on the spot: the SOF edge defines t=0.
        clk_ctr  = 0
        tq_ctr   = 0
        seg1_end = nom_seg1_end
        bit_end  = nom_bit_end
      else
        if tq_tick do
          clk_ctr = 0

          # Strobes fire on the tick that *completes* the segment, so both
          # compare the index of the TQ now ending.
          if tq_ctr == seg1_end do
            sp_reg  = 1
            sampled = rx
          end

          if tq_ctr == bit_end do
            tq_ctr   = 0
            seg1_end = nom_seg1_end
            bit_end  = nom_bit_end
            wp_reg   = 1
          else
            tq_ctr = tq_ctr + 1
          end
        else
          clk_ctr = clk_ctr + 1
        end

        # Soft resync. Placed after the tick logic so an edge arriving on a
        # boundary tick wins over the nominal reload.
        if resync_en and rx_fall do
          if tq_ctr > seg1_end do
            # Early edge, inside Phase Segment 2 -> shorten it, but never past
            # the sample point.
            if shortened > seg1_end do
              bit_end = shortened
            else
              bit_end = seg1_end
            end
          else
            # Late edge -> lengthen Phase Segment 1 and push the bit end out.
            seg1_end = seg1_end + adj_late
            bit_end  = bit_end + adj_late
          end
        end
      end
    end
  end

  # --- Elixir-side configuration helpers -------------------------------------

  @doc """
  Compute a parameter keyword list for a target bit rate.

  Picks the largest whole number of clocks per TQ that hits `bitrate` exactly
  with a legal segment count (8..25 TQ), then places the sample point as close
  to `sample_pct` as `PHASE_SEG2 >= 1` allows.

      Hw.CAN.BitTiming.config(48_000_000, 1_000_000)
      #=> [TQ_CLOCKS: 2, PROP_SEG: 8, PHASE_SEG1: 9, PHASE_SEG2: 6, SJW: 4]
      #   24 TQ x 2 clocks = 48 clocks/bit, sample point 75.0%

  Note this differs from the module defaults (8 TQ x 6 clocks), which reach the
  same 1 Mbit/s with a coarser bit. Both are legal; `config/2` prefers more time
  quanta because that buys finer sample-point placement and a wider usable SJW.

  Returns `{:error, :no_exact_divisor}` when no legal split divides the clock
  exactly — a fractional bit rate is never silently rounded, because a bit-rate
  error of even a percent accumulates across a frame and corrupts the far end
  of it.
  """
  def config(clk_freq, bitrate, sample_pct \\ nil) do
    pct = sample_pct || if bitrate >= 1_000_000, do: 75.0, else: 87.5

    candidates =
      for tq_per_bit <- 25..8//-1,
          rem(clk_freq, bitrate * tq_per_bit) == 0,
          do: {tq_per_bit, div(clk_freq, bitrate * tq_per_bit)}

    case candidates do
      [] ->
        {:error, :no_exact_divisor}

      list ->
        # Prefer more TQ per bit: finer resolution for the sample point and
        # for SJW.
        {tq_per_bit, tq_clocks} = Enum.max_by(list, fn {n, _} -> n end)
        split(tq_per_bit, tq_clocks, pct)
    end
  end

  defp split(tq_per_bit, tq_clocks, pct) do
    # Sample point index, clamped so Phase Segment 2 keeps at least 1 TQ.
    target = round(tq_per_bit * pct / 100.0)
    sp = min(target, tq_per_bit - 1)

    phase_seg2 = tq_per_bit - sp
    # Everything before the sample point, less the 1 TQ Sync Segment, split
    # between propagation and phase 1.
    before = sp - 1
    prop = div(before, 2)
    phase_seg1 = before - prop
    sjw = min(4, min(phase_seg1, phase_seg2))

    [
      TQ_CLOCKS: tq_clocks,
      PROP_SEG: prop,
      PHASE_SEG1: phase_seg1,
      PHASE_SEG2: phase_seg2,
      SJW: sjw
    ]
  end

  @doc """
  Actual sample point, as a percentage, for a given parameter list. Use this to
  check a hand-written configuration against the CiA recommendation.
  """
  def sample_point_pct(opts) do
    prop = Keyword.fetch!(opts, :PROP_SEG)
    ps1 = Keyword.fetch!(opts, :PHASE_SEG1)
    ps2 = Keyword.fetch!(opts, :PHASE_SEG2)
    total = 1 + prop + ps1 + ps2
    (1 + prop + ps1) * 100.0 / total
  end

  @doc "Bit rate produced by a parameter list at a given clock frequency."
  def bitrate(clk_freq, opts) do
    prop = Keyword.fetch!(opts, :PROP_SEG)
    ps1 = Keyword.fetch!(opts, :PHASE_SEG1)
    ps2 = Keyword.fetch!(opts, :PHASE_SEG2)
    tqc = Keyword.fetch!(opts, :TQ_CLOCKS)
    div(clk_freq, tqc * (1 + prop + ps1 + ps2))
  end
end
