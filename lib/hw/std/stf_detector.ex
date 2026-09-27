defmodule Hw.StfDetector do
  @moduledoc """
  Streaming 802.11-style L-STF detector: the first receive block of the
  OcuSync PHY in fabric (nervezynq notes/ocusync/02, 10). Bit-exact twin of
  `OcuSync.Phy.StfDetFixed` (nervezynq/ocusync) and of the model in
  `test/stf_detector_test.exs`.

  Per input sample (`valid` strobe, one per radio frame on DATA_CLK):

  1. **DC removal**, IIR: `dc = acc >> 7` (arithmetic), `y = x - dc`,
     `acc += y`: a high-pass with a ~10 kHz corner at 8 Msps (tau = 128
     samples), far below the nearest used subcarrier (125 kHz). The AD9363's
     RX DC is perfectly correlated at lag 16 and would otherwise look like a
     permanent plateau. Detection is blanked for the first 1024 samples after
     `enable` while the tracker settles. (A 1024-sample tau was the first
     choice; its residual DC fired false detections in the test.)
  2. **Lag-16 autocorrelation** over a 32-sample window, updated
     recursively: `P += y[t] conj(y[t-16]) - y[t-32] conj(y[t-48])`,
     `R += |y[t]|^2 - |y[t-32]|^2`.
  3. **Plateau test**: `4 |P|^2 > 3 R^2` (M > 0.75) and `R > emin`. The test
     is scale-invariant, so |Pr|, |Pi| and R share one right shift that
     leaves 17 significant bits (`sh` = bits of `|Pr| | |Pi| | R` above
     bit 16) before squaring: each square is 17 x 17, one DSP48, and the
     compare is 37 bits. (The first build squared the full 32 bits in LUT
     fabric: +2,900 LUTs, and the placement spread cost axi_clk 100 MHz.)
     `R > emin` uses the full 32-bit R.
  4. **Detect** on the 48th consecutive passing sample: one-cycle `detect`
     pulse, `P` and `R` latched (`det_pr`, `det_pi`, `det_r`; coarse CFO =
     atan2(P) / (2 pi 16) cycles per sample), `det_count` incremented. The
     window of the passing test that fires started 47 samples earlier, so
     the STF began 94 samples before the sample that fires.

  Arithmetic is unsigned and modular throughout: operands are sign-extended
  by concatenation and products are truncated to the width that holds the
  exact result. The EHDL simulator and the emitted Verilog then agree by
  construction (EHDL's Mul emits a plain `a * b`).

  Widths: y 13, products 26, P and R 32 (|P| < 2^30, R < 2^30), normalized
  17, squares 34, comparison 37.

  Pipeline: stage A on `valid` (DC, delay line), B (P, R), C (|P|, shared
  shift), C2 (normalize, squares), D (test, counter, detect). `valid` must
  be at least 4 cycles apart (one per 4 DATA_CLK cycles in 2R2T); stage D
  of one sample overlaps stage A of the next, which is independent.

  `emin` is in R units: 32 x mean |y|^2, y in 12-bit LSBs.

  Silicon (dr-b, 2026-09-26, bitstream det5 seed 29): 0 detections/s with
  the peer silent; 958 and 966 /s while dr-a replays a 976.6 PPDU/s ring at
  10 dB TX attenuation; coarse CFO -6.2 kHz, matching the offline estimate.
  The first bitstream fired ~1e5 /s on noise with P drifting without bound:
  yosys `xilinx_dsp` had packed the delay-line taps into DSP A/B registers
  and the square-sum into a P register, and that DSP configuration does not
  survive nextpnr-xilinx. The RTL was bit-exact under iverilog on the same
  captured samples (`test/stf_detector_test.exs`, :iverilog / :capture), so
  the build now maps multipliers to bare DSP48E1s (build.exs).
  """

  use Hw.Component

  clock :clk, freq: 32.0

  input :enable, 1
  input :valid, 1
  input :i, 12
  input :q, 12
  input :emin, 32

  output :detect, 1
  output :det_pr, 32
  output :det_pi, 32
  output :det_r, 32
  output :det_count, 16
  output :pass, 1

  # --- stage A: DC removal + delay line ---------------------------------------
  wire :acc_i, 19, init: 0
  wire :acc_q, 19, init: 0
  wire :warm, 10, init: 0
  wire :warm_done, 1, init: 0
  wire :xi13, 13
  wire :xq13, 13
  wire :dci13, 13
  wire :dcq13, 13
  wire :yi, 13
  wire :yq, 13
  wire :yi19, 19
  wire :yq19, 19
  wire :d0_i, 13, init: 0
  wire :d0_q, 13, init: 0
  wire :d1_i, 13, init: 0
  wire :d1_q, 13, init: 0
  wire :d2_i, 13, init: 0
  wire :d2_q, 13, init: 0
  wire :d3_i, 13, init: 0
  wire :d3_q, 13, init: 0
  wire :d4_i, 13, init: 0
  wire :d4_q, 13, init: 0
  wire :d5_i, 13, init: 0
  wire :d5_q, 13, init: 0
  wire :d6_i, 13, init: 0
  wire :d6_q, 13, init: 0
  wire :d7_i, 13, init: 0
  wire :d7_q, 13, init: 0
  wire :d8_i, 13, init: 0
  wire :d8_q, 13, init: 0
  wire :d9_i, 13, init: 0
  wire :d9_q, 13, init: 0
  wire :d10_i, 13, init: 0
  wire :d10_q, 13, init: 0
  wire :d11_i, 13, init: 0
  wire :d11_q, 13, init: 0
  wire :d12_i, 13, init: 0
  wire :d12_q, 13, init: 0
  wire :d13_i, 13, init: 0
  wire :d13_q, 13, init: 0
  wire :d14_i, 13, init: 0
  wire :d14_q, 13, init: 0
  wire :d15_i, 13, init: 0
  wire :d15_q, 13, init: 0
  wire :d16_i, 13, init: 0
  wire :d16_q, 13, init: 0
  wire :d17_i, 13, init: 0
  wire :d17_q, 13, init: 0
  wire :d18_i, 13, init: 0
  wire :d18_q, 13, init: 0
  wire :d19_i, 13, init: 0
  wire :d19_q, 13, init: 0
  wire :d20_i, 13, init: 0
  wire :d20_q, 13, init: 0
  wire :d21_i, 13, init: 0
  wire :d21_q, 13, init: 0
  wire :d22_i, 13, init: 0
  wire :d22_q, 13, init: 0
  wire :d23_i, 13, init: 0
  wire :d23_q, 13, init: 0
  wire :d24_i, 13, init: 0
  wire :d24_q, 13, init: 0
  wire :d25_i, 13, init: 0
  wire :d25_q, 13, init: 0
  wire :d26_i, 13, init: 0
  wire :d26_q, 13, init: 0
  wire :d27_i, 13, init: 0
  wire :d27_q, 13, init: 0
  wire :d28_i, 13, init: 0
  wire :d28_q, 13, init: 0
  wire :d29_i, 13, init: 0
  wire :d29_q, 13, init: 0
  wire :d30_i, 13, init: 0
  wire :d30_q, 13, init: 0
  wire :d31_i, 13, init: 0
  wire :d31_q, 13, init: 0
  wire :d32_i, 13, init: 0
  wire :d32_q, 13, init: 0
  wire :d33_i, 13, init: 0
  wire :d33_q, 13, init: 0
  wire :d34_i, 13, init: 0
  wire :d34_q, 13, init: 0
  wire :d35_i, 13, init: 0
  wire :d35_q, 13, init: 0
  wire :d36_i, 13, init: 0
  wire :d36_q, 13, init: 0
  wire :d37_i, 13, init: 0
  wire :d37_q, 13, init: 0
  wire :d38_i, 13, init: 0
  wire :d38_q, 13, init: 0
  wire :d39_i, 13, init: 0
  wire :d39_q, 13, init: 0
  wire :d40_i, 13, init: 0
  wire :d40_q, 13, init: 0
  wire :d41_i, 13, init: 0
  wire :d41_q, 13, init: 0
  wire :d42_i, 13, init: 0
  wire :d42_q, 13, init: 0
  wire :d43_i, 13, init: 0
  wire :d43_q, 13, init: 0
  wire :d44_i, 13, init: 0
  wire :d44_q, 13, init: 0
  wire :d45_i, 13, init: 0
  wire :d45_q, 13, init: 0
  wire :d46_i, 13, init: 0
  wire :d46_q, 13, init: 0
  wire :d47_i, 13, init: 0
  wire :d47_q, 13, init: 0
  wire :d48_i, 13, init: 0
  wire :d48_q, 13, init: 0

  # --- stage B: products and sliding sums --------------------------------------
  wire :vb, 1, init: 0
  wire :vc, 1, init: 0
  wire :vd, 1, init: 0
  wire :a0i, 26
  wire :a0q, 26
  wire :a16i, 26
  wire :a16q, 26
  wire :a32i, 26
  wire :a32q, 26
  wire :a48i, 26
  wire :a48q, 26
  wire :m_c_ii, 52
  wire :m_c_qq, 52
  wire :m_c_qi, 52
  wire :m_c_iq, 52
  wire :m_o_ii, 52
  wire :m_o_qq, 52
  wire :m_o_qi, 52
  wire :m_o_iq, 52
  wire :m_e0i, 52
  wire :m_e0q, 52
  wire :m_e32i, 52
  wire :m_e32q, 52
  wire :cur_r, 26
  wire :cur_i, 26
  wire :old_r, 26
  wire :old_i, 26
  wire :e_cur, 26
  wire :e_old, 26
  wire :cur_r32, 32
  wire :cur_i32, 32
  wire :old_r32, 32
  wire :old_i32, 32
  wire :e_cur32, 32
  wire :e_old32, 32
  wire :p_r, 32, init: 0
  wire :p_i, 32, init: 0
  wire :r_s, 32, init: 0

  # --- stage C: |P|, shared shift; C2: normalize + squares ------------------------
  wire :vc2, 1, init: 0
  wire :sgn_pr, 1
  wire :sgn_pi, 1
  wire :abs_pr, 32
  wire :abs_pi, 32
  wire :m_or, 32
  wire :o17, 4
  wire :o18, 4
  wire :o19, 4
  wire :o20, 4
  wire :o21, 4
  wire :o22, 4
  wire :o23, 4
  wire :o24, 4
  wire :o25, 4
  wire :o26, 4
  wire :o27, 4
  wire :o28, 4
  wire :o29, 4
  wire :o30, 4
  wire :o31, 4
  wire :nsh, 4
  wire :ca_pr, 32, init: 0
  wire :ca_pi, 32, init: 0
  wire :ca_r, 32, init: 0
  wire :ca_s, 4, init: 0
  wire :n_pr, 32
  wire :n_pi, 32
  wire :n_r, 32
  wire :n_pr17, 17
  wire :n_pi17, 17
  wire :n_r17, 17
  wire :sq_pr, 34
  wire :sq_pi, 34
  wire :sq_r, 34
  wire :sq_sum, 35
  wire :zero1, 1
  wire :zero2, 2
  wire :lhs_n, 37
  wire :rhs_n, 37
  wire :lhs, 37, init: 0
  wire :rhs, 37, init: 0
  wire :pr_c, 32, init: 0
  wire :pi_c, 32, init: 0
  wire :r_c, 32, init: 0

  # --- stage D: test, counter, detect -------------------------------------------
  wire :gt, 1
  wire :eg, 1
  wire :ok, 1
  wire :cnt, 6, init: 0
  wire :det_q, 1, init: 0
  wire :det_pr_q, 32, init: 0
  wire :det_pi_q, 32, init: 0
  wire :det_r_q, 32, init: 0
  wire :det_count_q, 16, init: 0
  wire :pass_q, 1, init: 0

  comb do
    xi13 = {i[11..11], i}
    xq13 = {q[11..11], q}
    dci13 = {acc_i[18..18], acc_i[18..7]}
    dcq13 = {acc_q[18..18], acc_q[18..7]}
    yi = xi13 - dci13
    yq = xq13 - dcq13
    yi19 = {replicate(yi[12..12], 6), yi}
    yq19 = {replicate(yq[12..12], 6), yq}

    a0i = {replicate(d0_i[12..12], 13), d0_i}
    a0q = {replicate(d0_q[12..12], 13), d0_q}
    a16i = {replicate(d16_i[12..12], 13), d16_i}
    a16q = {replicate(d16_q[12..12], 13), d16_q}
    a32i = {replicate(d32_i[12..12], 13), d32_i}
    a32q = {replicate(d32_q[12..12], 13), d32_q}
    a48i = {replicate(d48_i[12..12], 13), d48_i}
    a48q = {replicate(d48_q[12..12], 13), d48_q}

    # y[t] conj(y[t-16]) = (a0i a16i + a0q a16q) + j (a0q a16i - a0i a16q)
    m_c_ii = a0i * a16i
    m_c_qq = a0q * a16q
    m_c_qi = a0q * a16i
    m_c_iq = a0i * a16q
    m_o_ii = a32i * a48i
    m_o_qq = a32q * a48q
    m_o_qi = a32q * a48i
    m_o_iq = a32i * a48q
    m_e0i = a0i * a0i
    m_e0q = a0q * a0q
    m_e32i = a32i * a32i
    m_e32q = a32q * a32q

    cur_r = m_c_ii[25..0] + m_c_qq[25..0]
    cur_i = m_c_qi[25..0] - m_c_iq[25..0]
    old_r = m_o_ii[25..0] + m_o_qq[25..0]
    old_i = m_o_qi[25..0] - m_o_iq[25..0]
    e_cur = m_e0i[25..0] + m_e0q[25..0]
    e_old = m_e32i[25..0] + m_e32q[25..0]

    cur_r32 = {replicate(cur_r[25..25], 6), cur_r}
    cur_i32 = {replicate(cur_i[25..25], 6), cur_i}
    old_r32 = {replicate(old_r[25..25], 6), old_r}
    old_i32 = {replicate(old_i[25..25], 6), old_i}
    e_cur32 = zero_extend(e_cur, 32)
    e_old32 = zero_extend(e_old, 32)

    zero1 = 0
    zero2 = 0
    sgn_pr = p_r[31..31]
    sgn_pi = p_i[31..31]
    abs_pr = p_r
    abs_pi = p_i

    hdl_case <<sgn_pr::1>> do
      <<0::1>> -> abs_pr = p_r
      <<1::1>> -> abs_pr = bnot(p_r) + 1
    end

    hdl_case <<sgn_pi::1>> do
      <<0::1>> -> abs_pi = p_i
      <<1::1>> -> abs_pi = bnot(p_i) + 1
    end

    # Shared shift: number of bit positions 17..31 at or below the leading
    # one of |Pr| | |Pi| | R (the OR has the max's bit length).
    m_or = bor(bor(abs_pr, abs_pi), r_s)
    o17 = zero_extend(reduce_or(m_or[31..17]), 4)
    o18 = zero_extend(reduce_or(m_or[31..18]), 4)
    o19 = zero_extend(reduce_or(m_or[31..19]), 4)
    o20 = zero_extend(reduce_or(m_or[31..20]), 4)
    o21 = zero_extend(reduce_or(m_or[31..21]), 4)
    o22 = zero_extend(reduce_or(m_or[31..22]), 4)
    o23 = zero_extend(reduce_or(m_or[31..23]), 4)
    o24 = zero_extend(reduce_or(m_or[31..24]), 4)
    o25 = zero_extend(reduce_or(m_or[31..25]), 4)
    o26 = zero_extend(reduce_or(m_or[31..26]), 4)
    o27 = zero_extend(reduce_or(m_or[31..27]), 4)
    o28 = zero_extend(reduce_or(m_or[31..28]), 4)
    o29 = zero_extend(reduce_or(m_or[31..29]), 4)
    o30 = zero_extend(reduce_or(m_or[31..30]), 4)
    o31 = zero_extend(reduce_or(m_or[31..31]), 4)
    nsh = o17 + o18 + o19 + o20 + o21 + o22 + o23 + o24 + o25 + o26 + o27 + o28 + o29 + o30 + o31

    # C2: normalize to 17 bits and square (17 x 17: one DSP48 each).
    n_pr = ca_pr >>> ca_s
    n_pi = ca_pi >>> ca_s
    n_r = ca_r >>> ca_s
    n_pr17 = n_pr[16..0]
    n_pi17 = n_pi[16..0]
    n_r17 = n_r[16..0]
    sq_pr = n_pr17 * n_pr17
    sq_pi = n_pi17 * n_pi17
    sq_r = n_r17 * n_r17
    sq_sum = zero_extend(sq_pr, 35) + zero_extend(sq_pi, 35)
    # 4 (Pr^2 + Pi^2) and 3 R^2 = 2 R^2 + R^2, all < 2^37.
    lhs_n = {sq_sum, zero2}
    rhs_n = zero_extend({sq_r, zero1}, 37) + zero_extend(sq_r, 37)

    gt = lhs > rhs
    eg = r_c > emin
    ok = band(band(gt, eg), warm_done)

    detect = det_q
    det_pr = det_pr_q
    det_pi = det_pi_q
    det_r = det_r_q
    det_count = det_count_q
    pass = pass_q
  end

  on :clk do
    det_q = 0

    if enable == 0 do
      acc_i = 0
      acc_q = 0
      p_r = 0
      p_i = 0
      r_s = 0
      cnt = 0
      warm = 0
      warm_done = 0
      det_count_q = 0
      vb = 0
      vc = 0
      vc2 = 0
      vd = 0
      d0_i = 0
      d0_q = 0
      d1_i = 0
      d1_q = 0
      d2_i = 0
      d2_q = 0
      d3_i = 0
      d3_q = 0
      d4_i = 0
      d4_q = 0
      d5_i = 0
      d5_q = 0
      d6_i = 0
      d6_q = 0
      d7_i = 0
      d7_q = 0
      d8_i = 0
      d8_q = 0
      d9_i = 0
      d9_q = 0
      d10_i = 0
      d10_q = 0
      d11_i = 0
      d11_q = 0
      d12_i = 0
      d12_q = 0
      d13_i = 0
      d13_q = 0
      d14_i = 0
      d14_q = 0
      d15_i = 0
      d15_q = 0
      d16_i = 0
      d16_q = 0
      d17_i = 0
      d17_q = 0
      d18_i = 0
      d18_q = 0
      d19_i = 0
      d19_q = 0
      d20_i = 0
      d20_q = 0
      d21_i = 0
      d21_q = 0
      d22_i = 0
      d22_q = 0
      d23_i = 0
      d23_q = 0
      d24_i = 0
      d24_q = 0
      d25_i = 0
      d25_q = 0
      d26_i = 0
      d26_q = 0
      d27_i = 0
      d27_q = 0
      d28_i = 0
      d28_q = 0
      d29_i = 0
      d29_q = 0
      d30_i = 0
      d30_q = 0
      d31_i = 0
      d31_q = 0
      d32_i = 0
      d32_q = 0
      d33_i = 0
      d33_q = 0
      d34_i = 0
      d34_q = 0
      d35_i = 0
      d35_q = 0
      d36_i = 0
      d36_q = 0
      d37_i = 0
      d37_q = 0
      d38_i = 0
      d38_q = 0
      d39_i = 0
      d39_q = 0
      d40_i = 0
      d40_q = 0
      d41_i = 0
      d41_q = 0
      d42_i = 0
      d42_q = 0
      d43_i = 0
      d43_q = 0
      d44_i = 0
      d44_q = 0
      d45_i = 0
      d45_q = 0
      d46_i = 0
      d46_q = 0
      d47_i = 0
      d47_q = 0
      d48_i = 0
      d48_q = 0
    else
      vb = valid
      vc = vb
      vc2 = vc
      vd = vc2

      # Stage A
      if valid == 1 do
        acc_i = acc_i + yi19
        acc_q = acc_q + yq19

        if warm == 1023 do
          warm_done = 1
        else
          warm = warm + 1
        end
        d48_i = d47_i
        d48_q = d47_q
        d47_i = d46_i
        d47_q = d46_q
        d46_i = d45_i
        d46_q = d45_q
        d45_i = d44_i
        d45_q = d44_q
        d44_i = d43_i
        d44_q = d43_q
        d43_i = d42_i
        d43_q = d42_q
        d42_i = d41_i
        d42_q = d41_q
        d41_i = d40_i
        d41_q = d40_q
        d40_i = d39_i
        d40_q = d39_q
        d39_i = d38_i
        d39_q = d38_q
        d38_i = d37_i
        d38_q = d37_q
        d37_i = d36_i
        d37_q = d36_q
        d36_i = d35_i
        d36_q = d35_q
        d35_i = d34_i
        d35_q = d34_q
        d34_i = d33_i
        d34_q = d33_q
        d33_i = d32_i
        d33_q = d32_q
        d32_i = d31_i
        d32_q = d31_q
        d31_i = d30_i
        d31_q = d30_q
        d30_i = d29_i
        d30_q = d29_q
        d29_i = d28_i
        d29_q = d28_q
        d28_i = d27_i
        d28_q = d27_q
        d27_i = d26_i
        d27_q = d26_q
        d26_i = d25_i
        d26_q = d25_q
        d25_i = d24_i
        d25_q = d24_q
        d24_i = d23_i
        d24_q = d23_q
        d23_i = d22_i
        d23_q = d22_q
        d22_i = d21_i
        d22_q = d21_q
        d21_i = d20_i
        d21_q = d20_q
        d20_i = d19_i
        d20_q = d19_q
        d19_i = d18_i
        d19_q = d18_q
        d18_i = d17_i
        d18_q = d17_q
        d17_i = d16_i
        d17_q = d16_q
        d16_i = d15_i
        d16_q = d15_q
        d15_i = d14_i
        d15_q = d14_q
        d14_i = d13_i
        d14_q = d13_q
        d13_i = d12_i
        d13_q = d12_q
        d12_i = d11_i
        d12_q = d11_q
        d11_i = d10_i
        d11_q = d10_q
        d10_i = d9_i
        d10_q = d9_q
        d9_i = d8_i
        d9_q = d8_q
        d8_i = d7_i
        d8_q = d7_q
        d7_i = d6_i
        d7_q = d6_q
        d6_i = d5_i
        d6_q = d5_q
        d5_i = d4_i
        d5_q = d4_q
        d4_i = d3_i
        d4_q = d3_q
        d3_i = d2_i
        d3_q = d2_q
        d2_i = d1_i
        d2_q = d1_q
        d1_i = d0_i
        d1_q = d0_q
        d0_i = yi
        d0_q = yq
      end

      # Stage B
      if vb == 1 do
        p_r = p_r + cur_r32 - old_r32
        p_i = p_i + cur_i32 - old_i32
        r_s = r_s + e_cur32 - e_old32
      end

      # Stage C
      if vc == 1 do
        ca_pr = abs_pr
        ca_pi = abs_pi
        ca_r = r_s
        ca_s = nsh
        pr_c = p_r
        pi_c = p_i
        r_c = r_s
      end

      # Stage C2
      if vc2 == 1 do
        lhs = lhs_n
        rhs = rhs_n
      end

      # Stage D
      if vd == 1 do
        pass_q = ok

        if ok == 1 do
          if cnt == 47 do
            det_q = 1
            det_pr_q = pr_c
            det_pi_q = pi_c
            det_r_q = r_c
            det_count_q = det_count_q + 1
          end

          if cnt != 63 do
            cnt = cnt + 1
          end
        else
          cnt = 0
        end
      end
    end
  end
end
