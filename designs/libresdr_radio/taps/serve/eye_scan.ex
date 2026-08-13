defmodule Nervezynq.EyeScan do
  @moduledoc """
  Receive-margin measurement by IDELAYE2 tap sweep.

  ## What this measures, and why it is the first real margin number

  Until now the only evidence the LVDS receive path had margin was that it
  decoded. That is a pass/fail, and a pass/fail cannot distinguish "comfortably
  centred" from "one picosecond from the cliff". An `IDELAYE2` on each receive
  lane shifts the data relative to the sampling clock; decode at every tap and
  the set of taps that still decode IS the eye, measured on the actual board at
  the actual temperature with the actual cable.

  `IDELAY_TYPE` is FIXED, so the tap is a bitstream constant -- one bitstream
  per tap, each having independently won the routing lottery. They ship inside
  the firmware as gzip (a bitstream is ~4 MB raw, ~34 kB compressed) because
  `scp` to the Nerves sftp server truncates at 11294 bytes.

  ## The oracle

  The AD9363's BIST tone at Fs/32 is a known answer: 11.25 degrees per sample,
  constant magnitude. `Nervezynq.MIMO.validate/1` reports `deg_per_sample`,
  `mag_cv` and frame integrity against it. A tap that decodes gives
  `integrity 1.0`, `deg_per_sample 11.25`, `mag_cv ~3e-4`. A tap outside the eye
  degrades in a specific and readable way -- integrity falls first, because the
  frame lane fails before the data lanes lose the tone's structure.

  ## No IDELAYCTRL, so no picoseconds

  The taps are uncalibrated: without an `IDELAYCTRL` on a 200 MHz reference the
  delay per tap is process, voltage and temperature dependent rather than the
  datasheet's ~78 ps. The WIDTH of the eye in taps is still a real, comparable
  measurement, and the CENTRE is still the tap to ship. Do not convert to
  nanoseconds.

      iex> Nervezynq.EyeScan.run()
      iex> Nervezynq.EyeScan.report()
  """

  import Bitwise
  alias Nervezynq.{PL, AD9363, Fabric, MIMO}

  # Capture is done here against raw offsets rather than through
  # `Nervezynq.LVDSProbe`, deliberately. This module gets hot-loaded onto a
  # board whose firmware may be older than the tree it was compiled from --
  # `@cap_depth` has already differed once -- and a margin sweep that silently
  # captures 1024 words when it asked for 4096 would produce a plausible,
  # wrong eye. Self-contained means the sweep cannot be wrong about that.
  @ctrl2 0x14
  @status3 0x28

  @tap_dir "/root/idelay"
  # /lib/firmware is in the read-only rootfs (:erofs). `PL.reload/1` hands the
  # path straight to `devcfg_load`, which will read from anywhere, so the
  # writable /root mount is the right place to stage.
  @staged "/root/eyescan.bin"

  @doc """
  Every tap present, as `%{tap => [seed]}`.

  Files are `tap<N>_s<SEED>.bin.gz`. More than one seed per tap is not
  redundancy for its own sake -- see `measure/2`.
  """
  def taps do
    case File.ls(@tap_dir) do
      {:ok, files} ->
        files
        |> Enum.flat_map(fn f ->
          case Regex.run(~r/^tap(\d+)_s(\d+)\.bin\.gz$/, f) do
            [_, t, s] -> [{String.to_integer(t), String.to_integer(s)}]
            _ -> []
          end
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {t, seeds} -> {t, Enum.sort(seeds)} end)

      {:error, reason} ->
        {:error, {:no_tap_dir, @tap_dir, reason}}
    end
  end

  @doc """
  Load one tap's bitstream, re-run bring-up, capture, and score against the
  BIST tone.

  Every step that can fail returns rather than raising, because a tap OUTSIDE
  the eye is expected to fail and a sweep must not stop at the first one.
  """
  @doc """
  Measure one tap across ALL of its seeds, and take the best.

  This is not defensive padding. Seed 6 of this exact design routed, loaded,
  and reported correct magic, a running heartbeat and IDELAYCTRL `RDY`, while
  returning garbage over SPI. A single broken seed is indistinguishable from a
  genuinely closed eye, and would put a false notch in the middle of the
  measurement.

  So: a tap is OPEN if ANY seed decodes, and CLOSED only if EVERY seed fails.
  Disagreement between seeds is reported rather than averaged away, because it
  means the routing lottery is interfering with the measurement and the reader
  needs to know that.
  """
  def measure_tap(tap, opts \\ []) do
    seeds = Map.get(taps(), tap, [])
    tries = Keyword.get(opts, :tries, 3)

    # Capture start phase is random mod 4, so one capture that lands badly is
    # not evidence about the eye. Retry within a seed before moving on.
    results =
      Enum.map(seeds, fn seed ->
        {seed,
         Enum.reduce_while(1..tries, nil, fn _, _ ->
           case measure({tap, seed}, opts) do
             {:ok, r} = ok -> if decodes?(r), do: {:halt, ok}, else: {:cont, ok}
             err -> {:cont, err}
           end
         end)}
      end)
    good = for {seed, {:ok, r}} <- results, decodes?(r), do: {seed, r}

    case good do
      [] ->
        {:error, {:all_seeds_failed, tap, Enum.map(results, fn {s, r} -> {s, summarise(r)} end)}}

      [{seed, r} | _] ->
        {:ok, Map.merge(r, %{seed: seed, seeds_tried: length(seeds), seeds_ok: length(good)})}
    end
  end

  # `frame_integrity/1` is NOT a quality metric and must not gate anything. It
  # reads exactly 0.25 -- chance for a 4-phase cycle -- on captures that decode
  # perfectly, because it depends on where in the RX_FRAME cycle the capture
  # happened to start, and that is random mod 4. It read 0.25 on the known-good
  # `bank.bin` control in the same session it read 1.0 on another run of the
  # same bitstream. Gating on it declared a fully open eye CLOSED at every tap.
  #
  # The real discriminators are the two things the BIST tone predicts: the phase
  # advance per sample and the constancy of the magnitude.
  defp decodes?(r) do
    abs(r.ch1.deg_per_sample - 11.25) < 0.05 and r.ch1.mag_cv < 0.05
  end

  defp summarise({:ok, r}),
    do: %{deg: r.ch1.deg_per_sample, cv: r.ch1.mag_cv, integrity: r.integrity}
  defp summarise(other), do: other

  def measure(tap, opts \\ []) do
    try do
      do_measure(tap, opts)
    rescue
      e -> {:error, {tap, :raised, Exception.message(e)}}
    catch
      k, v -> {:error, {tap, :caught, {k, v}}}
    end
  end

  defp do_measure(tap, opts) do
    with :ok <- stage(tap),
         {:ok, info} <- PL.reload(@staged),
         :ok <- bringup(opts),
         {:ok, words} <- capture(4096) do
      # `validate/1` scores the tone; `frame_integrity/1` scores the framing.
      # Both matter, and they fail in that order as a tap leaves the eye.
      case MIMO.validate(words) do
        {:ok, stats} ->
          integrity =
            case MIMO.frame_integrity(words) do
              {:ok, f} -> f
              _ -> 0.0
            end

          {t, _} = tap
          {:ok, Map.merge(stats, %{tap: t, integrity: integrity, load_ms: info.ms})}

        other ->
          {:error, {tap, :decode, other}}
      end
    else
      {:error, reason} -> {:error, {tap, reason}}
      other -> {:error, {tap, other}}
    end
  end

  defp capture(n) do
    {:ok, c2} = Fabric.read32(@ctrl2)
    arm = bxor(c2 >>> 16 &&& 1, 1) <<< 16
    :ok = Fabric.write32(@ctrl2, arm)

    with :ok <- await_done(400) do
      {:ok,
       Enum.map(0..(n - 1), fn addr ->
         :ok = Fabric.write32(@ctrl2, arm ||| addr)
         {:ok, v} = Fabric.read32(@status3)
         v &&& 0x3FF_FFFF
       end)}
    end
  end

  defp await_done(0), do: {:error, :capture_timeout}

  defp await_done(n) do
    {:ok, v} = Fabric.read32(@status3)

    if (v >>> 26 &&& 1) == 1 do
      :ok
    else
      Process.sleep(1)
      await_done(n - 1)
    end
  end

  defp stage({tap, seed}) do
    src = Path.join(@tap_dir, "tap#{tap}_s#{seed}.bin.gz")

    case File.read(src) do
      {:ok, gz} -> File.write(@staged, :zlib.gunzip(gz))
      {:error, r} -> {:error, {:missing_bitstream, src, r}}
    end
  end

  # The transceiver keeps its SPI configuration across a PL reload -- it is a
  # separate chip -- but the fabric's SPI master and its RESETB line do not, so
  # the chip must be brought up again from scratch every time.
  defp bringup(opts) do
    rate = Keyword.get(opts, :sample_rate_hz, 4_000_000)
    bringup_try(rate, 3)
  end

  # The AD9363 does not always answer the first time after a PL reload: the
  # fabric's SPI master is new silicon-state and the transceiver's SPI state
  # machine only resynchronises on a RESETB pulse, so a readback of zeros on
  # attempt one is normal and means "reset it again", not "chip is dead".
  # Retrying matters more than usual here because a sweep must not attribute a
  # bring-up failure to a closed eye.
  defp bringup_try(_rate, 0), do: {:error, :bringup_failed}

  defp bringup_try(rate, n) do
    try do
      AD9363.release_reset()
      AD9363.enable_chip()
      # 50 ms is not enough after a PL reload; the first SPI readback comes
      # back as zeros and the whole tap looks like a closed eye.
      Process.sleep(200)

      # bist_tone/4 answers {:ok, reg}, NOT :ok. Matching on :ok here sent
      # every single tap into the retry loop and reported a uniformly closed
      # eye -- which is exactly what a real closed eye looks like, and is why
      # a sweep needs a control point it already knows the answer to.
      with {:ok, _} <- AD9363.Bringup.receive_path(rate),
           {:ok, _} <- AD9363.bist_tone(:rx, 0, 0, 0) do
        Process.sleep(50)
        :ok
      else
        _ -> bringup_try(rate, n - 1)
      end
    rescue
      _ -> bringup_try(rate, n - 1)
    catch
      _, _ -> bringup_try(rate, n - 1)
    end
  end

  @doc "Sweep every tap in the firmware. Returns one row per tap."
  def run(opts \\ []) do
    results =
      Enum.map(Map.keys(taps()) |> Enum.sort(), fn tap ->
        IO.write("  tap #{tap} ... ")
        r = measure_tap(tap, opts)

        case r do
          {:ok, s} ->
            IO.puts("integrity #{s.integrity} deg #{s.ch1.deg_per_sample} cv #{s.ch1.mag_cv}")

          {:error, e} ->
            IO.puts("FAIL #{inspect(e)}")
        end

        {tap, r}
      end)

    File.write!("/root/eyescan.exs", inspect(results, limit: :infinity, pretty: true))
    results
  end

  @doc "Render a sweep as an eye diagram, one row per tap."
  def report(results) do
    IO.puts("\n  tap  seed  ok/n  integrity  deg/sample  mag_cv     verdict")
    IO.puts("  ---  ----  ----  ---------  ----------  ---------  -------")

    Enum.each(results, fn
      {tap, {:ok, s}} ->
        :io.format("  ~3B  ~4B  ~2B/~1B  ~9.3f  ~10.3f  ~9.2e  OPEN~n", [
          tap, s.seed, s.seeds_ok, s.seeds_tried,
          s.integrity * 1.0, s.ch1.deg_per_sample * 1.0, s.ch1.mag_cv * 1.0
        ])

      {tap, {:error, {:all_seeds_failed, _, per_seed}}} ->
        :io.format("  ~3B  ~4s  0/~1B  ~9s  ~10s  ~9s  CLOSED~n", [
          tap, "-", length(per_seed), "-", "-", "-"
        ])

      {tap, {:error, e}} ->
        :io.format("  ~3B  ~4s  ~4s  ~9s  ~10s  ~9s  ERROR ~s~n", [
          tap, "-", "-", "-", "-", "-", inspect(e)
        ])
    end)

    open = for {t, {:ok, _}} <- results, do: t

    if open == [] do
      IO.puts("\n  No tap decoded. Do NOT read this as a closed eye until the")
      IO.puts("  tap-0 control has been shown to decode -- see HANDOFF.md.")
    else
      IO.puts("\n  eye open over taps #{inspect(open)}  (width #{length(open)} of #{map_size(taps())} sampled)")
      IO.puts("  centre tap ~= #{Enum.at(open, div(length(open), 2))}")
    end

    results
  end
end
