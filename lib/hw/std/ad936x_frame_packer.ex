defmodule Hw.AD936xFramePacker do
  @moduledoc """
  Pack the AD936x 2R2T LVDS receive stream into self-framing 64-bit words
  for the HP0 DMA path — one complete cross-channel sample pair per word.

  ## The word format (SINGLE SOURCE OF TRUTH)

  This layout is mirrored by `Nervezynq.SampleFormat.decode_stream_word/1`
  on the software side. Change them in the same commit or not at all.

      [11:0]   I1   rising-edge sample captured at frame phase 0 (sample_b)
      [23:12]  Q1   sample at frame phase 1 (sample_a)
      [35:24]  I2   sample at frame phase 2 (sample_b)
      [47:36]  Q2   sample at frame phase 3 (sample_a)
      [61:48]  SEQ  frame sequence, wraps mod 16384
      [62]     ERR  this word is the first complete frame after a resync
      [63]     0    reserved

  All four samples are raw 12-bit two's complement as delivered by the
  fabric edge assembly — the same `sample_a = {rise_q_d, rise_q}` order the
  snapshot path carries, so the stream decodes with `nibble_swap: false`
  exactly like `LVDSProbe.capture/1` words do. This component does not touch
  sample bit order at all; it only selects and labels.

  ## Why one frame per beat

  A frame boundary IS a beat boundary: 8-beat bursts carry 8 whole frames,
  the ring wraps on burst boundaries, and any readout window of the DDR ring
  cuts between frames, never through one. `SEQ` makes every word
  self-describing, so gapless-ness is checkable per adjacent word (`+1 mod
  16384`) with no external state — the streaming equivalent of the counter
  demo's `+1` invariant.

  ## Frame walk

  `RX_FRAME` in pulse mode gives the measured cycle `[3,1,0,2]` on the
  `frame_pair` bits (`{fall, rise}` order — see `Nervezynq.MIMO`). The field
  selection matches `MIMO.decode/2` exactly:

      phase 0 (pair==3) -> I1 = sample_b     phase 1 (pair==1) -> Q1 = sample_a
      phase 2 (pair==0) -> I2 = sample_b     phase 3 (pair==2) -> Q2 = sample_a

  A `3` is treated as frame start unconditionally: if it arrives while a
  frame is mid-assembly, the partial frame is discarded, `sync_lost` goes
  sticky, and assembly restarts — so one corrupted `RX_FRAME` bit costs one
  frame, not the stream. Any other unexpected value likewise drops the
  partial frame and waits for the next `3`. The first complete frame after
  either event carries the `ERR` bit.

  ## Domains and hand-off

  Everything here runs on the transceiver's `DATA_CLK` — same no-reset rule
  as the rest of that domain (init values only; the domain may have no clock
  at all until the AD9363 is configured). `word` is a level signal that
  changes only on emit, and `word_toggle` flips once per emit: the standard
  toggle-stabilised bus hand-off. The consumer synchronises the toggle
  (`Hw.CDC.Sync2`), edge-detects, and samples `word` — which by then has
  been stable for the 2–3 destination cycles the synchroniser took, and
  stays stable for a further 4 DATA_CLK periods (the next frame's assembly
  time). At 100 MHz consuming from a ≤61.44 MHz DATA_CLK the margin never
  goes below ~35 ns.

  `enable` must arrive already synchronised into this domain. While low:
  assembly state, `SEQ` and `sync_lost` all clear, so every stream start
  begins at SEQ 0 with clean flags. `word`/`word_toggle` deliberately do NOT
  reset — a toggle that snapped back to zero could read as a spurious edge
  downstream.

  Memoryless by construction, like `Hw.AXIHPWriter` and for the same
  reason: the simulator cannot execute `MemWrite`, and this component being
  pure registers is what lets the packer -> FIFO -> writer composition be
  testbenched end to end.
  """

  use Hw.Component

  # Measured DATA_CLK at the 8 Msps V1 operating point is 32.01 MHz. freq:
  # is load-bearing for simulation (Hw.Sim.Clock divides by it at init).
  clock :clk, freq: 32.0

  input :enable, 1
  input :sample_a, 12
  input :sample_b, 12
  input :frame_pair, 2

  output :word, 64
  output :word_toggle, 1
  output :sync_lost, 1

  # Assembly state: 0 = waiting for frame start, 1..3 = fields latched so far.
  wire :state, 2, init: 0
  wire :i1, 12, init: 0
  wire :q1, 12, init: 0
  wire :i2, 12, init: 0
  wire :seq, 14, init: 0
  wire :frame_err, 1, init: 0

  wire :word_q, 64, init: 0
  wire :toggle_q, 1, init: 0
  wire :lost_q, 1, init: 0
  wire :zero1, 1

  comb do
    zero1 = 0
    word = word_q
    word_toggle = toggle_q
    sync_lost = lost_q
  end

  on :clk do
    if enable == 0 do
      state = 0
      seq = 0
      frame_err = 0
      lost_q = 0
    else
      if frame_pair == 3 do
        # Frame start, unconditionally. Arriving mid-assembly means the
        # previous frame was torn: flag it, drop it, start fresh.
        if state != 0 do
          lost_q = 1
          frame_err = 1
        end

        i1 = sample_b
        state = 1
      else
        if state == 1 and frame_pair == 1 do
          q1 = sample_a
          state = 2
        else
          if state == 2 and frame_pair == 0 do
            i2 = sample_b
            state = 3
          else
            if state == 3 and frame_pair == 2 do
              # Q2 is THIS cycle's sample_a; the other three fields and
              # frame_err read as their previously-latched values
              # (nonblocking semantics).
              word_q = {zero1, frame_err, seq, sample_a, i2, q1, i1}
              toggle_q = bxor(toggle_q, 1)
              seq = seq + 1
              frame_err = 0
              state = 0
            else
              # Unexpected frame value. Mid-assembly it tears the frame;
              # in state 0 it is just the wait for the next frame start
              # (only ever seen right after enable or a resync).
              if state != 0 do
                lost_q = 1
                frame_err = 1
                state = 0
              end
            end
          end
        end
      end
    end
  end
end
