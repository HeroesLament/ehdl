# Nervezynq.SDR — a bladeRF-shaped V1 driver facade for the LibreSDR.
#
# Hot-loadable like the other instruments:
#
#     Code.compile_file("/data/sdr.exs")
#     {:ok, _} = Nervezynq.SDR.open(frequency: 2_412_000_000,
#                                   sample_rate: 8_000_000, gain_db: 40)
#     {:ok, st} = Nervezynq.SDR.selftest()      # BIST tone, known answer
#     {:ok, rx} = Nervezynq.SDR.rx(1000)        # %{ch1: [{i,q}], ch2: [{i,q}]}
#
# ## What this is
#
# The thin orchestration layer over modules that already exist and are
# already silicon-proven one level down: `AD9363.Bringup.rf_receive_path/3`
# (SPI init, clocks, synth cal, LO, gain tables, analog cal),
# `LVDSProbe.capture/1` (the 4096-word snapshot buffer), and `MIMO.decode/2`
# (the measured 2R2T frame walk). The API names lean on libbladeRF so the
# shape is familiar: open / set_frequency / set_sample_rate / set_gain /
# enable / rx / close.
#
# ## What V1 deliberately is NOT
#
# * NOT streaming. `rx/1` is snapshot capture: up to ~1020 sample pairs per
#   call, gapless WITHIN a capture, with dead time between calls. The
#   HP0 DMA engine (proven 2026-08-02, HPDMA_SESSION.md) is the V2 path;
#   it needs the sample-packing + FIFO fabric revision before radio data
#   rides it. The register map and this API are shaped so that lands as
#   a new `stream_rx/2` without breaking anything here.
# * NOT a calibrated receiver. Bringup's own moduledoc lists what is still
#   untranscribed (DC offset cal, quadrature tracking). Expect a DC term
#   and image energy; signals are real but numbers are not lab-grade.
# * NOT TX. The fabric has no TX path yet (O-side campaign, TRANSCEIVER
#   risk map Tier B).
#
# ## Platform prep is part of open/1, because of 2026-08-02
#
# `open/1` releases the FCLK throttle (SLCR THR_CNT=1 on this firmware
# stops every PL clock — HPDMA_SESSION.md) and refreshes the Fabric guard,
# then proves the AXI link with the magic register before touching the
# radio. Every step is idempotent; open/1 after a reboot is the whole
# ritual.

defmodule Nervezynq.SDR do
  @moduledoc "bladeRF-shaped V1 facade. See file header."

  alias Nervezynq.{AD9363, Fabric, LVDSProbe, MIMO, SLCR}
  alias Nervezynq.AD9363.{Bringup, Clocks, ENSM, Gain, RFPLL, RxAnalog}

  @magic 0x45484431
  @cap_depth 4096
  # FPGA0/1_THR_CNT. A count of 1 halts the FCLK; 0 is free-running.
  @thr_cnt [0x178, 0x188]

  # This bitstream (libresdr_radio + HP0 DMA) carries the FIXED fabric sample
  # assembly — sample_a = {rise_q_d, rise_q} (HANDOFF remaining-work #1, now
  # done in top.ex). So software must NOT nibble-swap. Measured on silicon
  # 2026-08-02: nibble_swap:false gives 11.25 deg/sample, mag_cv 3.4e-4,
  # |z|~2047 under the Fs/32 tone; nibble_swap:true gives 62 deg, cv 0.38.
  # MIMO's own @fabric_needs_nibble_swap default predates this fabric fix, so
  # every decode here passes the option explicitly rather than trusting it.
  @nibble_swap false

  defp state_agent, do: __MODULE__.State

  # --- lifecycle --------------------------------------------------------------

  @doc """
  Bring the platform and the receive path up. Idempotent.

  Options: `:frequency` (Hz, default 2.412e9), `:sample_rate` (Hz, default
  8e6), `:gain_db` (default 40), plus anything `Bringup.rf_receive_path/3`
  accepts.
  """
  def open(opts \\ []) do
    freq = Keyword.get(opts, :frequency, 2_412_000_000)
    fs = Keyword.get(opts, :sample_rate, 8_000_000)
    gain = Keyword.get(opts, :gain_db, 40)

    with :ok <- ensure_platform(),
         {:ok, rf} <- Bringup.rf_receive_path(freq, fs, Keyword.put(opts, :gain_db, gain)),
         :ok <- data_format_setup() do
      st = %{
        frequency: freq,
        sample_rate: fs,
        gain_db: gain,
        data_clk_mhz: rf.measured_data_clk_mhz,
        data_clk_agrees: rf.data_clk_agrees,
        opened_at: System.monotonic_time(:second)
      }

      case Process.whereis(state_agent()) do
        nil -> Agent.start(fn -> st end, name: state_agent())
        _ -> Agent.update(state_agent(), fn _ -> st end)
      end

      {:ok, st}
    end
  end

  @doc "ENSM to ALERT — synthesisers up, no RX. The polite idle."
  def close do
    with {:ok, _} <- ENSM.set_state(:alert), do: :ok
  end

  # --- tuning ------------------------------------------------------------------

  @doc "Retune the RX LO. Reloads the gain table across band boundaries."
  def set_frequency(hz) do
    with {:ok, r} <- Bringup.retune(hz, gain_db: get(:gain_db)) do
      put(:frequency, hz)
      {:ok, %{frequency: hz, lo: r.lo}}
    end
  end

  def frequency, do: get(:frequency)

  @doc """
  Change the sample rate. Re-runs the clock chain AND the analog chain —
  filter corner, TIA and ADC all depend on the BBPLL/ADC rates, so a rate
  change without them is a different (worse) receiver at the new rate.
  """
  def set_sample_rate(hz, opts \\ []) do
    bw = Keyword.get(opts, :rx_bb_bw_hz, div(hz, 2))

    with {:ok, clk} <- Clocks.set_sample_rate(hz, opts),
         {:ok, _} <- RxAnalog.setup(bw, clk.rx.bbpll, clk.rx.adc) do
      put(:sample_rate, hz)
      {:ok, %{sample_rate: hz, predicted_data_clk_mhz: clk.predicted_data_clk_mhz}}
    end
  end

  def sample_rate, do: get(:sample_rate)

  @doc "Manual gain, dB. Table-quantised by the chip; returns what was set."
  def set_gain(db) do
    with {:ok, g} <- Gain.set_gain_db(get(:frequency), db) do
      put(:gain_db, db)
      {:ok, g}
    end
  end

  @doc "`:mgc` (manual, default) or whatever Gain.set_mode/1 accepts."
  def set_gain_mode(mode), do: Gain.set_mode(mode)

  @doc "ENSM control: `:rx`, `:alert`, `:fdd`, `:tx`."
  def enable(target \\ :rx), do: ENSM.set_state(target)

  # --- receive -------------------------------------------------------------------

  @doc """
  Capture `n` sample pairs per channel (snapshot, not stream).

  Returns `{:ok, %{ch1: [{i, q}], ch2: [{i, q}], samples: n', fs: hz}}` —
  `n'` may be a few less than asked after frame alignment. Max ~1020 per
  call (4096-word buffer, 4 words per sample pair).
  """
  def rx(n \\ 1000) when n > 0 do
    words_wanted = min(n * 4 + 8, @cap_depth)

    with {:ok, words} <- LVDSProbe.capture(words_wanted),
         {:ok, d} <- MIMO.decode(words, nibble_swap: @nibble_swap) do
      {:ok,
       %{
         ch1: Enum.take(d.ch1, n),
         ch2: Enum.take(d.ch2, n),
         samples: min(d.samples, n),
         frame_offset: d.frame_offset,
         fs: get(:sample_rate),
         frequency: get(:frequency)
       }}
    end
  end

  @doc """
  Continuous receive over the HP0 DMA ring — the V2 streaming path.

  Requires the DMA-radio bitstream (hp_dma_s1+) and `hp_stream.exs` loaded;
  `open/1` must have run (radio up, ENSM in RX). `dest` is a pid or 1-arity
  fun receiving `{:hp_stream, meta, payload}` — see `Nervezynq.HPStream`.

  This is DECIMATED delivery (newest window per poll, waterfall-shaped).
  For gapless beacon-depth capture use `stream_capture/2`.
  """
  def stream_rx(dest, opts \\ []) do
    with :ok <- ensure_stream_loaded(), do: Nervezynq.HPStream.stream_rx(dest, opts)
  end

  @doc "Stop the streaming consumer and disable the DMA engine."
  def stream_stop do
    with :ok <- ensure_stream_loaded(), do: Nervezynq.HPStream.stop_stream()
  end

  @doc """
  Gapless capture of `bytes` of stream (≤ ~960 KB; 262144 = 32768 frames =
  4.1 ms at 8 Msps, 32x the snapshot depth). Returns decoded ch1/ch2 plus
  the SEQ continuity proof (`seq.holes == 0` means not one frame missing).
  """
  def stream_capture(bytes \\ 262_144, opts \\ []) do
    with :ok <- ensure_stream_loaded(), do: Nervezynq.HPStream.capture_burst(bytes, opts)
  end

  defp ensure_stream_loaded do
    if Code.ensure_loaded?(Nervezynq.HPStream) do
      :ok
    else
      {:error, :hp_stream_not_loaded}
    end
  end

  @doc "One capture as interleaved signed-16 binary: <<i1,q1,i2,q2,...>> ch1 only."
  def rx_binary(n \\ 1000) do
    with {:ok, r} <- rx(n) do
      {:ok,
       for {i, q} <- r.ch1, into: <<>> do
         <<i::little-signed-16, q::little-signed-16>>
       end}
    end
  end

  # --- verification ------------------------------------------------------------------

  @doc """
  Known-answer self-test: inject the Fs/32 BIST tone at the RX control
  point, capture, and check the two invariants that caught every decode
  bug this project has had — constant magnitude (mag_cv) and +11.25
  deg/sample on BOTH channels. Restores normal ADC data afterwards.

  Pass: |deg - 11.25| < 0.5 and mag_cv < 0.01 on both channels.
  """
  def selftest do
    with {:ok, _} <- AD9363.bist_tone(:rx, 0, 0, 0),
         {:ok, words} <- LVDSProbe.capture(2048),
         {:ok, v} <- MIMO.validate(words, nibble_swap: @nibble_swap),
         {:ok, _} <- AD9363.bist_tone(:disable) do
      pass = fn ch -> abs(ch.deg_per_sample - 11.25) < 0.5 and ch.mag_cv < 0.01 end

      {:ok,
       %{
         pass: pass.(v.ch1) and pass.(v.ch2),
         ch1: v.ch1,
         ch2: v.ch2,
         predicted_deg: v.predicted_deg,
         frame_offset: v.frame_offset
       }}
    end
  end

  @doc "Everything worth knowing, one map. Safe to call any time after open."
  def status do
    {:ok, ensm} = ENSM.state()
    {:ok, lo} = RFPLL.lo_freq()

    %{
      driver: Agent.get(state_agent(), & &1),
      ensm: ensm,
      lo: lo,
      rx_locked: RFPLL.vco_locked?(:rx),
      data_clk_mhz: LVDSProbe.data_clk_mhz(200)
    }
  end

  # --- platform ----------------------------------------------------------------------

  @doc """
  PS-side prep, all idempotent: FCLK throttle release (the 2026-08-02 root
  cause — THR_CNT=1 stops every PL clock while the divisor registers read
  as configured), Fabric guard refresh, magic-register proof of the AXI
  link. Raises nothing; returns `{:error, ...}` with the failing gate.
  """
  def ensure_platform do
    with :ok <- ensure_slcr(),
         :ok <- release_fclk_throttle(),
         :ok <- ensure_pl(),
         :ok <- ensure_axi() do
      :ok
    end
  end

  defp ensure_slcr do
    case Process.whereis(SLCR) do
      nil ->
        case SLCR.start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          e -> e
        end

      _ ->
        :ok
    end
  end

  defp release_fclk_throttle do
    throttled? =
      Enum.any?(@thr_cnt, fn off ->
        {:ok, v} = SLCR.read32(off)
        v != 0
      end)

    if throttled? do
      SLCR.unlock()
      Enum.each(@thr_cnt, &SLCR.write32(&1, 0))
      SLCR.lock()
    end

    :ok
  end

  defp ensure_pl do
    # PlLoad may not be compiled in every session; the devcfg PCFG_DONE bit
    # through it is the clean gate when it is. Fall back to trusting the
    # magic check below.
    cond do
      Code.ensure_loaded?(PlLoad) and function_exported?(PlLoad, :pcfg_done?, 0) ->
        if PlLoad.pcfg_done?(), do: :ok, else: {:error, :pl_unconfigured}

      true ->
        :ok
    end
  end

  defp ensure_axi do
    Fabric.authorise()

    case Fabric.read32(0x00) do
      {:ok, @magic} -> :ok
      {:ok, other} -> {:error, {:bad_magic, other}}
      e -> e
    end
  end

  # --- data format (canonical receive procedure, HANDOFF) ---------------------------

  defp data_format_setup do
    # RX_FRAME pulse mode (0x010 bit 3): level mode aliases to DC.
    _ = AD9363.writef(0x010, 0x08, 1)
    # PP_RX_SWAP_IQ (bit 6) = 1, RX_CHANNEL_SWAP (bit 4) = 0 — the measured
    # combination behind ch1/ch2 = RX1/RX2 with correct conjugation.
    _ = AD9363.writef(0x010, 0x40, 1)
    _ = AD9363.writef(0x010, 0x10, 0)
    :ok
  end

  # --- tiny state helpers ---------------------------------------------------------------

  defp get(key), do: Agent.get(state_agent(), &Map.fetch!(&1, key))
  defp put(key, val), do: Agent.update(state_agent(), &Map.put(&1, key, val))
end
