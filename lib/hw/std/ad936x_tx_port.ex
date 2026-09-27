defmodule Hw.AD936xTxPort do
  @moduledoc """
  AD936x 2R2T LVDS transmit framer: four 12-bit samples per frame onto six
  DDR lanes plus TX_FRAME, as rising/falling-edge values for `Hw.Xilinx.ODDR`
  (`DDR_CLK_EDGE: "SAME_EDGE"`: D1 goes out on the rising edge, D2 on the
  falling edge of the same cycle).

  ## Edge order (mirror of the measured receive side)

  The receive path assembles every 12-bit sample from two consecutive
  SAME-edge 6-bit words (`sample_a = {rise_q_d, rise_q}`, `sample_b =
  {fall_q_d, fall_q}` in top.ex), with Q samples on one edge polarity and I
  samples on the other (`Hw.AD936xFramePacker`: I from sample_b, Q from
  sample_a). So the wire carries I and Q interleaved edge by edge, MSB half
  first — the AD936x LVDS 2R2T order:

      frame=1:  I1msb Q1msb I1lsb Q1lsb     frame=0:  I2msb Q2msb I2lsb Q2lsb

  In ODDR terms (D1 = rising edge, D2 = falling edge of the same cycle):

      phase 0: rise = I1[11:6]  fall = Q1[11:6]   frame 1 1
      phase 1: rise = I1[5:0]   fall = Q1[5:0]    frame 1 1
      phase 2: rise = I2[11:6]  fall = Q2[11:6]   frame 0 0
      phase 3: rise = I2[5:0]   fall = Q2[5:0]    frame 0 0

  (A first draft of this module sent each sample's two halves on the two
  edges of one cycle. The receive-side assembly contradicts that; it was
  corrected before any build.)

  ## Why the order is switchable, and not trusted

  The table is derived from the receive measurements; transmit has never
  been on silicon. So the three swaps are runtime inputs — `half_swap`: LSB
  half first; `iq_swap`: Q on the rising edge; `chan_swap`: channel 2 in the
  frame=1 half — and the AD9363's internal data-port loopback
  (REG_OBSERVE_CONFIG 0x3F5 bit 0) settles them with register writes, not
  rebuilds. The forwarded clock's phase is the instantiator's (ODDR D1/D2
  on FB_CLK).

  ## Timing

  `enable` must already be synchronised into `clk` (DATA_CLK). While low,
  every output is 0 and the phase counter holds at 0. The four sample inputs
  are latched on the last cycle of each frame, in the cycle `sample_req`
  pulses; the source must present the next frame's samples by then (a
  counter advanced on `sample_req` does). The first frame after enable
  carries whatever was latched before, i.e. zeros from init.

  Memoryless, like the packer, so it testbenches in the EHDL simulator.
  """

  use Hw.Component

  # DATA_CLK at the 8 Msps operating point (measured 32.01 MHz). freq: is
  # load-bearing for simulation.
  clock :clk, freq: 32.0

  input :enable, 1
  input :i1, 12
  input :q1, 12
  input :i2, 12
  input :q2, 12
  input :half_swap, 1
  input :iq_swap, 1
  input :chan_swap, 1

  output :d_rise, 6
  output :d_fall, 6
  output :frame_rise, 1
  output :frame_fall, 1
  output :sample_req, 1

  wire :phase, 2, init: 0
  wire :l_i1, 12, init: 0
  wire :l_q1, 12, init: 0
  wire :l_i2, 12, init: 0
  wire :l_q2, 12, init: 0
  wire :rise_q, 6, init: 0
  wire :fall_q, 6, init: 0
  wire :frame_q, 1, init: 0

  # After swaps: (ra, fa) = the rising/falling-edge samples of the frame=1
  # half, (rb, fb) = those of the frame=0 half.
  wire :c1r, 12
  wire :c1f, 12
  wire :c2r, 12
  wire :c2f, 12
  wire :ra, 12
  wire :fa, 12
  wire :rb, 12
  wire :fb, 12
  wire :r_cur, 12
  wire :f_cur, 12
  wire :lo_half, 1
  wire :r_out, 6
  wire :f_out, 6

  comb do
    d_rise = rise_q
    d_fall = fall_q
    frame_rise = frame_q
    frame_fall = frame_q
    sample_req = band(enable, phase == 3)

    # iq_swap: Q on the rising edge.
    c1r = l_i1
    c1f = l_q1
    c2r = l_i2
    c2f = l_q2
    hdl_case <<iq_swap::1>> do
      <<0::1>> ->
        c1r = l_i1
        c1f = l_q1
        c2r = l_i2
        c2f = l_q2
      <<1::1>> ->
        c1r = l_q1
        c1f = l_i1
        c2r = l_q2
        c2f = l_i2
    end

    # chan_swap: channel 2 in the frame=1 half.
    ra = c1r
    fa = c1f
    rb = c2r
    fb = c2f
    hdl_case <<chan_swap::1>> do
      <<0::1>> ->
        ra = c1r
        fa = c1f
        rb = c2r
        fb = c2f
      <<1::1>> ->
        ra = c2r
        fa = c2f
        rb = c1r
        fb = c1f
    end

    # Phases 0,1 carry the frame=1 pair; 2,3 the frame=0 pair.
    r_cur = ra
    f_cur = fa
    hdl_case <<phase::2>> do
      <<0::2>> ->
        r_cur = ra
        f_cur = fa
      <<1::2>> ->
        r_cur = ra
        f_cur = fa
      <<2::2>> ->
        r_cur = rb
        f_cur = fb
      <<3::2>> ->
        r_cur = rb
        f_cur = fb
    end

    # Even phase sends the MSB half, odd the LSB half; half_swap inverts.
    lo_half = bxor(phase[0..0], half_swap)
    r_out = r_cur[11..6]
    f_out = f_cur[11..6]
    hdl_case <<lo_half::1>> do
      <<0::1>> ->
        r_out = r_cur[11..6]
        f_out = f_cur[11..6]
      <<1::1>> ->
        r_out = r_cur[5..0]
        f_out = f_cur[5..0]
    end
  end

  on :clk do
    if enable == 0 do
      phase = 0
      rise_q = 0
      fall_q = 0
      frame_q = 0
    else
      phase = phase + 1
      rise_q = r_out
      fall_q = f_out

      if phase == 0 or phase == 1 do
        frame_q = 1
      else
        frame_q = 0
      end

      # Last cycle of the frame: latch the next frame's samples. The
      # output registers above read this cycle's (old) latched values.
      if phase == 3 do
        l_i1 = i1
        l_q1 = q1
        l_i2 = i2
        l_q2 = q2
      end
    end
  end
end
