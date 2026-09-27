# Nervezynq.TxTone: first transmit. The AD9363's own BIST tone, injected at the
# TX control point, out through the TX synthesiser, no fabric TX path needed.
#
# Hot-loaded like sdr.exs, and requires it (SDR.open must have run: it powers
# and CP-calibrates BOTH synthesisers and enables the TX channels, but only
# ever tunes the RX LO):
#
#     Code.compile_file("/data/tx_tone.exs")
#     Nervezynq.TxTone.set_tx_atten(30.0)            # dB, 0.25 dB steps
#     {:ok, lo} = Nervezynq.TxTone.set_tx_lo(2_413_000_000)
#     Nervezynq.TxTone.key(tone: 0, level_db: 0)     # tone at TX LO + Fs*(n+1)/32
#     Nervezynq.TxTone.unkey()                       # ALERT, BIST off, atten max
#
# ## What is transcribed from where (ADI no-OS, drivers/rf-transceiver/ad9361)
#
# * TX synth = RX synth register block + 0x40. ad9361_rfpll_vco_init():
#   `offs = REG_TX_VCO_OUTPUT - REG_RX_VCO_OUTPUT` (0x27A - 0x23A). Same
#   SynthLUT, TDD table (this driver runs TDD; FDD tables apply only when
#   TX and RX LOs differ in FDD). The in-tree RFPLL.set_lo/2 is the RX-only
#   instance of exactly this sequence; the writes below mirror it with offs.
# * Frequency word: REG_TX_FRACT_BYTE_2 (0x275) descending to
#   REG_TX_INTEGER_BYTE_0 (0x271), with the same read-modify-write on
#   REG_TX_INTEGER_BYTE_1 (0x272) bits 7:3 as the RX side.
# * VCO divider: REG_RFPLL_DIVIDERS (0x005), TX_VCO_DIVIDER = bits 7:4.
# * Lock: RFPLL.vco_locked?(:tx) (REG_TX_CP_OVERRANGE_VCO_LOCK 0x287).
# * Attenuation: ad9361_set_tx_atten(): 0.25 dB/LSB, 9-bit, written as a
#   2-byte descending burst at REG_TX1_ATTEN_1 (0x074, bit 0 = MSB) then 0x073,
#   same for TX2 at 0x076/0x075, bracketed by IMMEDIATELY_UPDATE_TPC_ATTEN
#   (bit 6 of REG_TX2_DIG_ATTEN 0x07C) cleared before and set after.
#   Max 89.75 dB.
#
# ## What is NOT done, so what to expect on air
#
# No TX quadrature calibration and no TX baseband/secondary filter
# calibration are transcribed yet. Expect, besides the tone at LO + f_tone:
# LO leakage at the TX LO itself, and an image at LO - f_tone. Their levels
# relative to the tone are a measurement worth keeping, not a fault.
#
# ## Emissions
#
# 2.4 GHz ISM. Default attenuation is the maximum; key() refuses to run
# below `@min_atten_db` unless forced. No PA on this board: 0 dB attenuation
# is single-digit dBm at the connector.

defmodule Nervezynq.TxTone do
  @moduledoc "AD9363 BIST tone out the TX path. See file header."

  import Bitwise
  alias Nervezynq.AD9363
  alias Nervezynq.AD9363.{ENSM, RFPLL, SynthLUT}

  @offs 0x40

  # RX-side addresses (as in RFPLL); the TX block is these + @offs.
  @reg_vco_output 0x23A
  @reg_alc_varactor 0x239
  @reg_vco_bias_1 0x242
  @reg_force_vco_tune_1 0x238
  @reg_vco_varactor_ctrl_1 0x251
  @reg_vco_cal_ref 0x245
  @reg_vco_varactor_ctrl_0 0x250
  @reg_cp_current 0x23B
  @reg_loop_filter_1 0x23E
  @reg_loop_filter_2 0x23F
  @reg_loop_filter_3 0x240
  @reg_fract_byte_2 0x235
  @reg_integer_byte_1 0x232

  @porb_vco_logic 0x40
  @reg_rfpll_dividers 0x005
  @tx_vco_divider 0xF0

  @reg_tx1_atten_1 0x074
  @reg_tx2_atten_1 0x076
  @reg_tx2_dig_atten 0x07C
  @immediately_update_tpc_atten 0x40
  @max_atten_db 89.75
  @min_atten_db 10.0
  @max_burst_ms 10_000

  @doc """
  Tune the TX LO. Mirrors RFPLL.set_lo/2 on the TX register block.
  `ref_clk_hz` must match what the RX side was tuned with (80 MHz default,
  as RFPLL.set_lo/2 uses).
  """
  def set_tx_lo(freq_hz, opts \\ []) do
    ref = Keyword.get(opts, :ref_clk_hz, 80_000_000)
    d = RFPLL.calc_divider(freq_hz, ref)

    with {:ok, row} <- SynthLUT.row(:tdd, SynthLUT.range(ref), d.vco_hz),
         :ok <- vco_init(row),
         :ok <- write_freq_word(d),
         :ok <- AD9363.writef(@reg_rfpll_dividers, @tx_vco_divider, d.vco_div),
         {:ok, lock} <- await_lock(200) do
      {:ok,
       %{
         requested_hz: freq_hz,
         actual_hz: RFPLL.recalc(d, ref),
         vco_hz: d.vco_hz,
         vco_div: d.vco_div,
         vco_locked: lock,
         readback_hz: tx_lo_freq(ref)
       }}
    end
  end

  defp vco_init(row) do
    :ok = AD9363.write(@reg_vco_output + @offs, row.vco_output_level &&& 0x0F ||| @porb_vco_logic)
    :ok = AD9363.writef(@reg_alc_varactor + @offs, 0x0F, row.vco_varactor)
    :ok = AD9363.write(@reg_vco_bias_1 + @offs, (row.vco_bias_tcf &&& 0x03) <<< 3 ||| (row.vco_bias_ref &&& 0x07))
    :ok = AD9363.write(@reg_force_vco_tune_1 + @offs, (row.vco_cal_offset &&& 0x0F) <<< 3)
    :ok = AD9363.write(@reg_vco_varactor_ctrl_1 + @offs, row.vco_varactor_reference &&& 0x0F)
    :ok = AD9363.write(@reg_vco_cal_ref + @offs, 0x00)
    :ok = AD9363.write(@reg_vco_varactor_ctrl_0 + @offs, 7 <<< 4)
    :ok = AD9363.writef(@reg_cp_current + @offs, 0x3F, row.charge_pump_current)
    :ok = AD9363.write(@reg_loop_filter_1 + @offs, (row.lf_c2 &&& 0x0F) <<< 4 ||| (row.lf_c1 &&& 0x0F))
    :ok = AD9363.write(@reg_loop_filter_2 + @offs, (row.lf_r1 &&& 0x0F) <<< 4 ||| (row.lf_c3 &&& 0x0F))
    :ok = AD9363.write(@reg_loop_filter_3 + @offs, row.lf_r3 &&& 0x0F)
    :ok
  end

  defp write_freq_word(%{integer: integer, fract: fract}) do
    {:ok, cur} = AD9363.read(@reg_integer_byte_1 + @offs)

    AD9363.write_multi(@reg_fract_byte_2 + @offs, [
      fract >>> 16 &&& 0x7F,
      fract >>> 8 &&& 0xFF,
      fract &&& 0xFF,
      (integer >>> 8 &&& 0x07) ||| (cur &&& 0xF8),
      integer &&& 0xFF
    ])
  end

  defp await_lock(0), do: {:error, :tx_vco_lock_timeout}

  defp await_lock(n) do
    if RFPLL.vco_locked?(:tx) do
      {:ok, true}
    else
      Process.sleep(1)
      await_lock(n - 1)
    end
  end

  @doc "Read back the programmed TX LO."
  def tx_lo_freq(ref \\ 80_000_000) do
    {:ok, b2} = AD9363.read(0x275)
    {:ok, b1} = AD9363.read(0x274)
    {:ok, b0} = AD9363.read(0x273)
    {:ok, i1} = AD9363.read(0x272)
    {:ok, i0} = AD9363.read(0x271)
    {:ok, dv} = AD9363.read(@reg_rfpll_dividers)

    d = %{
      fract: (b2 &&& 0x7F) <<< 16 ||| b1 <<< 8 ||| b0,
      integer: (i1 &&& 0x07) <<< 8 ||| i0,
      vco_div: dv >>> 4 &&& 0x0F
    }

    RFPLL.recalc(d, ref)
  end

  @doc "TX1 and TX2 attenuation in dB (0..89.75, 0.25 dB steps)."
  def set_tx_atten(db) when db >= 0 and db <= @max_atten_db do
    code = round(db * 4)
    buf = [code >>> 8 &&& 0x01, code &&& 0xFF]

    :ok = AD9363.writef(@reg_tx2_dig_atten, @immediately_update_tpc_atten, 0)
    :ok = AD9363.write_multi(@reg_tx1_atten_1, buf)
    :ok = AD9363.write_multi(@reg_tx2_atten_1, buf)
    :ok = AD9363.writef(@reg_tx2_dig_atten, @immediately_update_tpc_atten, 1)
    {:ok, %{atten_db: code / 4, readback: tx_atten()}}
  end

  @doc "Read back TX1/TX2 attenuation in dB."
  def tx_atten do
    rd = fn hi, lo ->
      {:ok, h} = AD9363.read(hi)
      {:ok, l} = AD9363.read(lo)
      ((h &&& 1) <<< 8 ||| l) / 4
    end

    %{tx1: rd.(0x074, 0x073), tx2: rd.(0x076, 0x075)}
  end

  @doc """
  Key the transmitter with a BIST tone. Options: `:tone` (index 0..3, tone at
  Fs*(n+1)/32 above the TX LO), `:level_db` (0/6/12/18 below full scale),
  `:mask` (see AD9363.bist_tone/4), `:force` (allow attenuation below
  #{@min_atten_db} dB).
  """
  def key(opts \\ []) do
    %{tx1: atten} = tx_atten()

    if atten < @min_atten_db and not Keyword.get(opts, :force, false) do
      {:error, {:atten_below_floor, atten, @min_atten_db}}
    else
      with {:ok, bist} <- AD9363.bist_tone(:tx, Keyword.get(opts, :tone, 0), Keyword.get(opts, :level_db, 0), Keyword.get(opts, :mask, 0)),
           {:ok, _} <- ENSM.set_state(:tx) do
        {:ok, %{bist_config: bist, ensm: ENSM.state(), tx_atten: tx_atten(), tx_lo_hz: tx_lo_freq()}}
      end
    end
  end

  @doc "Unkey: ENSM to ALERT, BIST off, attenuation to maximum."
  def unkey do
    ENSM.set_state(:alert)
    AD9363.bist_tone(:disable)
    set_tx_atten(@max_atten_db)
    {:ok, %{ensm: ENSM.state(), tx_atten: tx_atten()}}
  end

  @doc """
  Key for a bounded time, then unkey, enforced on this board.

  Returns as soon as the carrier is up. The unkey runs in an unlinked process
  that sleeps `ms` and then calls `unkey/0`, so neither a dropped ssh session
  nor a stalled receiver can leave a carrier on air. Added after 2026-09-23,
  when an interrupted ssh chain left dr-a keyed and unreachable until it was
  power-cycled.

  Options as `key/1`, plus `:atten_db` (default 30.0) set before keying.
  `ms` is capped at #{@max_burst_ms} ms.
  """
  def burst(ms, opts \\ []) when is_integer(ms) and ms > 0 and ms <= @max_burst_ms do
    {:ok, _} = set_tx_atten(Keyword.get(opts, :atten_db, 30.0))

    case key(opts) do
      {:ok, info} ->
        pid = spawn(fn -> Process.sleep(ms); unkey() end)
        {:ok, Map.merge(info, %{burst_ms: ms, unkey_pid: pid})}

      err ->
        unkey()
        err
    end
  end

  # --- TX quadrature calibration --------------------------------------------
  #
  # Transcribed from ad9361_tx_quad_calib(), __ad9361_tx_quad_calib(),
  # ad9361_tx_quad_phase_search() and ad9361_find_opt() (no-OS ad9361.c).
  #
  # Deliberately omitted:
  # * __ad9361_update_rf_bandwidth(): ADI widens the analog filters only when
  #   the cal NCO lands above BW/4. The TX baseband filter calibrations it
  #   calls are not transcribed; quad_cal/1 refuses rather than run with an
  #   NCO the filters were not set up for.
  # * RX1/RX2 phase-inversion handling: not enabled in this tree.
  # * last_tx_quad_cal_phase retry: no persistent phy state here, so a
  #   non-converging first attempt goes straight to the 32-phase search.

  @reg_tx_enable_filter_ctrl 0x002
  @reg_calibration_ctrl 0x016
  @cal_tx_quad 0x10
  @reg_quad_cal_nco 0x0A0
  @reg_quad_cal_ctrl 0x0A1
  @reg_kexp_1 0x0A2
  @reg_kexp_2 0x0A3
  @reg_quad_settle_count 0x0A4
  @reg_mag_ftest_thresh 0x0A5
  @reg_mag_ftest_thresh_2 0x0A6
  @reg_quad_cal_status_tx1 0x0A7
  @reg_quad_cal_count 0x0A9
  @reg_tx_quad_full_lmt_gain 0x0AA
  @reg_tx_quad_lpf_gain 0x0AE
  @tx1_converged 0x03

  @doc """
  Run the AD9363 TX quadrature (image + LO leakage) calibration for TX1.

  Options: `:sample_rate_hz` (8 MHz, must match SDR.open), `:bw_tx_hz` /
  `:bw_rx_hz` (default the sample rate), `:atten_db` during the cal (30.0;
  restored to maximum afterwards). ENSM is forced to ALERT for the cal and
  restored to its previous state.

  Returns the NCO/phase choices, whether TX1 LO and SSB converged, whether
  the phase search ran (and its 64-slot map, `#` = fail), and the resulting
  TX1 correction registers.
  """
  def quad_cal(opts \\ []) do
    sr = Keyword.get(opts, :sample_rate_hz, 8_000_000)
    bw_tx = Keyword.get(opts, :bw_tx_hz, sr)
    bw_rx = Keyword.get(opts, :bw_rx_hz, sr)
    {:ok, %{rx: rx, tx: tx}} = Nervezynq.AD9363.Clocks.calculate(sr)
    clkrf = Enum.at(rx, 4)
    clktf = Enum.at(tx, 4)

    txnco0 = (div(bw_tx * 8 + div(clktf, 2), clktf) - 1) |> max(0) |> min(3)
    decim = if clktf <= 4_000_000, do: 2, else: 3

    with {:ok, rx_phase, txnco, rxnco} <- nco_plan(clkrf, clktf, txnco0),
         txnco_freq = div(clktf * (txnco + 1), 32),
         :ok <- bw_guard(txnco_freq, bw_rx, bw_tx),
         {:ok, lo} <- RFPLL.lo_freq(),
         {:ok, lpf_match} <- lpf_tia_match(lo.lo_hz) do
      {:ok, prev} = ENSM.state()
      {:ok, _} = set_tx_atten(Keyword.get(opts, :atten_db, 30.0))
      {:ok, _} = ENSM.set_state(:alert)

      try do
        :ok = AD9363.writef(@reg_kexp_2, 0xC0, txnco)
        :ok = AD9363.write(@reg_quad_cal_count, 0xFF)
        # KEXP_TX(1) | KEXP_TX_COMP(3) | KEXP_DC_I(3) | KEXP_DC_Q(3)
        :ok = AD9363.write(@reg_kexp_1, 1 <<< 6 ||| 3 <<< 4 ||| 3 <<< 2 ||| 3)
        :ok = AD9363.write(@reg_mag_ftest_thresh, 0x03)
        :ok = AD9363.write(@reg_mag_ftest_thresh_2, 0x03)
        :ok = AD9363.write(@reg_tx_quad_full_lmt_gain, lpf_match)
        :ok = AD9363.write(@reg_quad_settle_count, 0xF0)
        :ok = AD9363.write(@reg_tx_quad_lpf_gain, 0x00)

        {:ok, first} = run_quad(rx_phase, rxnco, decim)

        {phase, status, search} =
          if first == @tx1_converged do
            {rx_phase, first, nil}
          else
            phase_search(rxnco, decim)
          end

        {:ok,
         %{
           clkrf: clkrf,
           clktf: clktf,
           txnco_word: txnco,
           rxnco_word: rxnco,
           nco_hz: txnco_freq,
           decim: decim,
           lpf_tia_match: lpf_match,
           rx_phase_initial: rx_phase,
           rx_phase_used: phase,
           first_status: first,
           lo_converged: (status &&& 0x02) != 0,
           ssb_converged: (status &&& 0x01) != 0,
           phase_search: search,
           corrections: tx1_corrections()
         }}
      after
        ENSM.set_state(prev.state)
        set_tx_atten(@max_atten_db)
      end
    end
  end

  # ad9361_tx_quad_calib(): pick RX phase / adjust NCO words by clock ratio.
  defp nco_plan(clkrf, clktf, txnco) when clkrf == 2 * clktf do
    case txnco do
      0 -> {:ok, 0x0E, 1, 0}
      1 -> {:ok, 0x0E, 1, 0}
      2 -> {:ok, 0x0E, 1, 0}
      3 -> {:ok, 0x08, 3, 1}
    end
  end

  defp nco_plan(clk, clk, txnco) do
    phase =
      case txnco do
        t when t in [0, 3] ->
          0x15

        2 ->
          0x1F

        1 ->
          {:ok, v} = AD9363.read(@reg_tx_enable_filter_ctrl)
          if (v &&& 0x3F) == 0x22, do: 0x15, else: 0x1A
      end

    {:ok, phase, txnco, txnco}
  end

  defp nco_plan(clkrf, clktf, _), do: {:error, {:unhandled_clock_ratio, clkrf, clktf}}

  defp bw_guard(nco, bw_rx, bw_tx) do
    if nco > div(bw_rx, 4) or nco > div(bw_tx, 4),
      do: {:error, {:needs_tx_filter_cal, nco, div(bw_rx, 4), div(bw_tx, 4)}},
      else: :ok
  end

  # ad9361_load_gt(): the last row whose TIA/LPF word matches 0x20 under the
  # full-table mask 0x3F.
  defp lpf_tia_match(lo_hz) do
    with {:ok, band} <- Nervezynq.AD9363.GainTable.band(lo_hz) do
      band
      |> Nervezynq.AD9363.GainTable.rows()
      |> Enum.with_index()
      |> Enum.filter(fn {{_w1, w2, _w3, _db}, _i} -> (w2 &&& 0x3F) == 0x20 end)
      |> case do
        [] -> {:error, :no_lpf_tia_match}
        hits -> {:ok, hits |> List.last() |> elem(1)}
      end
    end
  end

  # __ad9361_tx_quad_calib()
  defp run_quad(phase, rxnco, decim) do
    ctrl = 0x40 ||| 0x20 ||| 0x10 ||| 0x08 ||| (decim &&& 0x3)
    :ok = AD9363.write(@reg_quad_cal_nco, (rxnco &&& 0x3) <<< 5 ||| (phase &&& 0x1F))
    :ok = AD9363.write(@reg_quad_cal_ctrl, ctrl ||| 0x04)
    :ok = AD9363.write(@reg_quad_cal_ctrl, ctrl)
    :ok = AD9363.write(@reg_calibration_ctrl, @cal_tx_quad)

    with :ok <- await_cal(2000) do
      {:ok, v} = AD9363.read(@reg_quad_cal_status_tx1)
      {:ok, v &&& 0x03}
    end
  end

  defp await_cal(0), do: {:error, :tx_quad_cal_timeout}

  defp await_cal(n) do
    {:ok, v} = AD9363.read(@reg_calibration_ctrl)

    if (v &&& @cal_tx_quad) == 0 do
      :ok
    else
      Process.sleep(1)
      await_cal(n - 1)
    end
  end

  # ad9361_tx_quad_phase_search() + ad9361_find_opt()
  defp phase_search(rxnco, decim) do
    fails =
      for i <- 0..31 do
        {:ok, v} = run_quad(i, rxnco, decim)
        if v == @tx1_converged, do: 0, else: 1
      end

    field = fails ++ fails
    {start, cnt} = find_opt(field)
    phase = (start + div(cnt, 2)) &&& 0x1F
    {:ok, final} = run_quad(phase, rxnco, decim)
    map = Enum.map_join(field, fn f -> if f == 1, do: "#", else: "o" end)
    {phase, final, %{map: map, best_run: cnt, start: start}}
  end

  defp find_opt(field) do
    {best, _cur} =
      field
      |> Enum.with_index()
      |> Enum.reduce({{0, 0}, {-1, 0}}, fn
        {0, i}, {best, {-1, _}} -> step_best(best, {i, 1})
        {0, _i}, {best, {s, c}} -> step_best(best, {s, c + 1})
        {_, _i}, {best, _} -> {best, {-1, 0}}
      end)

    best
  end

  defp step_best({bs, bc}, {s, c} = cur), do: if(c > bc, do: {{s, c}, cur}, else: {{bs, bc}, cur})

  @doc "TX1 quadrature/offset correction registers (0x08E..0x093), raw."
  def tx1_corrections do
    for {name, reg} <- [phase: 0x08E, gain: 0x08F, offset_i: 0x092, offset_q: 0x093], into: %{} do
      {:ok, v} = AD9363.read(reg)
      {name, v}
    end
  end
end
