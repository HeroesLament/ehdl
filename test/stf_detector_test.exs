defmodule Hw.StfDetectorTest do
  use ExUnit.Case
  import Bitwise

  alias Hw.StfDetector

  # --- bit-exact integer model (the spec) ---------------------------------------
  # Returns [{t, pr, pi, r}] for each detection; t = index of the sample that fires.
  def model(samples, emin) do
    init = %{warm: 0, acc_i: 0, acc_q: 0, hist: :queue.from_list(List.duplicate({0, 0}, 49)), pr: 0, pi: 0, r: 0, cnt: 0, dets: []}

    samples
    |> Enum.with_index()
    |> Enum.reduce(init, fn {{i, q}, t}, s ->
      yi = i - (s.acc_i >>> 7)
      yq = q - (s.acc_q >>> 7)
      acc_i = wrap(s.acc_i + yi, 19)
      acc_q = wrap(s.acc_q + yq, 19)
      # Blanking: the RTL sets warm_done on the valid of sample 1023 and stage D
      # of that same sample sees it, so detections are allowed from t = 1023.
      warm_done = s.warm >= 1023
      {_, h} = :queue.out(s.hist)
      h = :queue.in({yi, yq}, h)
      l = :queue.to_list(h)
      # l is oldest first: index 48 = y[t], 32 = y[t-16], 16 = y[t-32], 0 = y[t-48].
      {a0i, a0q} = Enum.at(l, 48)
      {a16i, a16q} = Enum.at(l, 32)
      {a32i, a32q} = Enum.at(l, 16)
      {a48i, a48q} = Enum.at(l, 0)
      pr = s.pr + (a0i * a16i + a0q * a16q) - (a32i * a48i + a32q * a48q)
      pi = s.pi + (a0q * a16i - a0i * a16q) - (a32q * a48i - a32i * a48q)
      r = s.r + (a0i * a0i + a0q * a0q) - (a32i * a32i + a32q * a32q)
      ok = plateau?(pr, pi, r) and r > emin and warm_done

      {cnt, dets} =
        cond do
          not ok -> {0, s.dets}
          s.cnt == 47 -> {48, [{t, pr, pi, r} | s.dets]}
          s.cnt == 63 -> {63, s.dets}
          true -> {s.cnt + 1, s.dets}
        end

      %{s | warm: min(s.warm + 1, 1024), acc_i: acc_i, acc_q: acc_q, hist: h, pr: pr, pi: pi, r: r, cnt: cnt, dets: dets}
    end)
    |> Map.fetch!(:dets)
    |> Enum.reverse()
  end

  # 4|P|^2 > 3R^2 on a shared 17-significant-bit normalization of |Pr|, |Pi|, R.
  def plateau?(pr, pi, r) do
    {apr, api} = {abs(pr), abs(pi)}
    m = apr ||| api ||| r
    sh = max(0, bitlen(m) - 17)
    {a, b, c} = {apr >>> sh, api >>> sh, r >>> sh}
    4 * (a * a + b * b) > 3 * c * c
  end

  defp bitlen(0), do: 0
  defp bitlen(m), do: length(Integer.digits(m, 2))

  defp wrap(v, w) do
    m = v &&& (1 <<< w) - 1
    if m >= 1 <<< (w - 1), do: m - (1 <<< w), else: m
  end

  defp s32(v) when v >= 1 <<< 31, do: v - (1 <<< 32)
  defp s32(v), do: v

  # --- stimulus --------------------------------------------------------------------
  @stf %{-24 => 1, -20 => -1, -16 => 1, -12 => -1, -8 => -1, -4 => 1, 4 => -1, 8 => -1, 12 => 1, 16 => 1, 20 => 1, 24 => 1}

  defp stf(amp) do
    a = :math.sqrt(13 / 6) / :math.sqrt(52)

    for n <- 0..159 do
      {re, im} =
        Enum.reduce(@stf, {0.0, 0.0}, fn {k, v}, {x, y} ->
          w = 2 * :math.pi() * k * n / 64
          # (1 + j) v a e^{jw}
          {x + v * a * (:math.cos(w) - :math.sin(w)), y + v * a * (:math.cos(w) + :math.sin(w))}
        end)

      {round(re * amp), round(im * amp)}
    end
  end

  defp lcg(n, seed) do
    {out, _} = Enum.map_reduce(1..n, seed, fn _, s -> s = rem(s * 1_103_515_245 + 12_345, 2_147_483_648); {s, s} end)
    out
  end

  defp noise(n, amp, seed), do: lcg(2 * n, seed) |> Enum.chunk_every(2) |> Enum.map(fn [a, b] -> {rem(a, 2 * amp + 1) - amp, rem(b, 2 * amp + 1) - amp} end)

  defp qpsk(n, amp, seed), do: lcg(n, seed) |> Enum.map(fn s -> {if(band(s, 0x10000) == 0, do: amp, else: -amp), if(band(s, 0x20000) == 0, do: amp, else: -amp)} end)

  defp add(xs, ys), do: Enum.zip_with(xs, ys, fn {a, b}, {c, d} -> {clamp(a + c), clamp(b + d)} end)
  defp clamp(v), do: v |> max(-2048) |> min(2047)
  defp dc(n, {di, dq}), do: List.duplicate({di, dq}, n)

  # --- simulator driver ----------------------------------------------------------
  defp run_sim(samples, emin) do
    {:ok, sim} = Hw.Sim.start(StfDetector)
    Hw.Sim.set(sim, :emin, emin)
    Hw.Sim.set(sim, :valid, 0)
    Hw.Sim.set(sim, :enable, 0)
    Hw.Sim.tick(sim, :clk, 2)
    Hw.Sim.set(sim, :enable, 1)

    # Stage D of sample t lands on the cycle of sample t+1's valid edge, so a
    # pulse seen right after that edge belongs to t; pulses in the three idle
    # cycles belong to the current sample (checked too, so a pipeline change
    # cannot silently drop them).
    seen = fn owner ->
      if Hw.Sim.get(sim, :detect) == 1,
        do: [{owner, s32(Hw.Sim.get(sim, :det_pr)), s32(Hw.Sim.get(sim, :det_pi)), Hw.Sim.get(sim, :det_r)}],
        else: []
    end

    dets =
      samples
      |> Enum.with_index()
      |> Enum.flat_map(fn {{i, q}, t} ->
        Hw.Sim.set(sim, :i, i &&& 0xFFF)
        Hw.Sim.set(sim, :q, q &&& 0xFFF)
        Hw.Sim.set(sim, :valid, 1)
        Hw.Sim.tick(sim, :clk, 1)
        at_valid = seen.(t - 1)
        Hw.Sim.set(sim, :valid, 0)
        idle = Enum.flat_map(1..3, fn _ -> Hw.Sim.tick(sim, :clk, 1); seen.(t) end)
        at_valid ++ idle
      end)

    # Flush the pipeline after the last sample.
    tail = Enum.flat_map(1..6, fn _ -> Hw.Sim.tick(sim, :clk, 1); seen.(length(samples) - 1) end)
    {dets ++ tail, Hw.Sim.get(sim, :det_count)}
  end


  # --- iverilog co-simulation of the emitted RTL ------------------------------------
  # The EHDL simulator and the emitted Verilog are separate evaluators; the
  # bitstream runs the latter. Same drive pattern as run_sim/2.
  @iverilog System.get_env("IVERILOG") ||
              System.find_executable("iverilog") ||
              (File.exists?(Path.expand("~/oss-cad-suite/bin/iverilog")) &&
                 Path.expand("~/oss-cad-suite/bin/iverilog")) || nil

  def run_verilog(samples, emin) do
    dir = Path.join(System.tmp_dir!(), "stf_cosim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      dut = Path.join(dir, "stf_detector.v")
      File.write!(dut, Hw.emit(Hw.Compile.Elaborate.elaborate(StfDetector)))
      tb = Path.expand("support/verilog/tb_stf_detector.v", __DIR__)
      bin = Path.join(dir, "tb.vvp")
      {out, rc} = System.cmd(@iverilog, ["-g2012", "-o", bin, "-s", "tb", tb, dut], stderr_to_stdout: true)
      if rc != 0, do: raise("iverilog: " <> out)

      hex = fn v -> v |> band(0xFFF) |> Integer.to_string(16) end
      stim = ["#{length(samples)} #{emin}\n" | Enum.map(samples, fn {i, q} -> "#{hex.(i)} #{hex.(q)}\n" end)]
      File.write!(Path.join(dir, "stim.txt"), stim)
      vvp = Path.join(Path.dirname(@iverilog), "vvp")
      {_, 0} = System.cmd(vvp, ["-n", bin], stderr_to_stdout: true, cd: dir)

      lines = dir |> Path.join("out.txt") |> File.read!() |> String.split("\n", trim: true)
      {dets, ["C " <> c]} = Enum.split(lines, -1)

      dets =
        Enum.map(dets, fn l ->
          [t, pr, pi, r] = String.split(l)
          h = &String.to_integer(&1, 16)
          {String.to_integer(t), s32(h.(pr)), s32(h.(pi)), h.(r)}
        end)

      {dets, String.to_integer(c)}
    after
      File.rm_rf!(dir)
    end
  end

  test "two STFs through DC offset and noise: simulator == model, one detection each, at the STF" do
    # First STF after the 1024-sample blanking.
    n0 = 1100
    gap = 200
    x =
      dc(n0, {0, 0}) ++
        stf(500) ++ qpsk(250, 180, 7) ++ dc(gap, {0, 0}) ++ stf(300) ++ qpsk(250, 110, 9) ++ dc(100, {0, 0})

    x = x |> add(noise(length(x), 12, 3)) |> add(dc(length(x), {310, -205}))
    emin = 32 * 2 * 12 * 12

    want = model(x, emin)
    {got, count} = run_sim(x, emin)

    assert got == want
    assert count == length(want)
    assert length(want) == 2
    starts = Enum.map(want, fn {t, _, _, _} -> t - 94 end)
    stf2 = n0 + 160 + 250 + gap
    [s1, s2] = starts
    assert abs(s1 - n0) <= 4, inspect(starts)
    assert abs(s2 - stf2) <= 4, inspect(starts)
  end

  test "DC + noise alone never fires (the IIR removes the DC's lag-16 correlation)" do
    x = noise(1500, 12, 11) |> add(dc(1500, {400, 250}))
    emin = 32 * 2 * 12 * 12
    assert model(x, emin) == []
    assert run_sim(x, emin) == {[], 0}
  end

  test "coarse CFO from the latched P: a rotating STF gives the programmed offset" do
    # +20 kHz at 8 Msps = 0.0025 cycles/sample; P angle = 2 pi 16 f.
    f = 0.0025
    x =
      (dc(1100, {0, 0}) ++ stf(500) ++ dc(200, {0, 0}))
      |> Enum.with_index()
      |> Enum.map(fn {{a, b}, n} ->
        w = 2 * :math.pi() * f * n
        {round(a * :math.cos(w) - b * :math.sin(w)), round(a * :math.sin(w) + b * :math.cos(w))}
      end)
      |> add(noise(1460, 8, 5))

    {[{_, pr, pi, _}], 1} = run_sim(x, 32 * 2 * 8 * 8)
    est = :math.atan2(pi, pr) / (2 * :math.pi() * 16)
    assert_in_delta est, f, 0.0002
  end
  @tag :iverilog
  @tag timeout: 600_000
  test "emitted Verilog == model (two STFs, DC, noise)" do
    if is_nil(@iverilog), do: flunk("iverilog not found")
    n0 = 1100
    x = dc(n0, {0, 0}) ++ stf(500) ++ qpsk(250, 180, 7) ++ dc(200, {0, 0}) ++ stf(300) ++ qpsk(250, 110, 9) ++ dc(100, {0, 0})
    x = x |> add(noise(length(x), 12, 3)) |> add(dc(length(x), {310, -205}))
    emin = 32 * 2 * 12 * 12
    want = model(x, emin)
    assert length(want) == 2
    assert run_verilog(x, emin) == {want, 2}
  end

  @tag :iverilog
  @tag timeout: 600_000
  test "emitted Verilog == model on DC + noise (no detections)" do
    if is_nil(@iverilog), do: flunk("iverilog not found")
    x = noise(1500, 12, 11) |> add(dc(1500, {400, 250}))
    assert run_verilog(x, 32 * 2 * 12 * 12) == {[], 0}
  end

  # A real capture: STF_CAPTURE=path/to/capture.b64 (base64 LE u64 words,
  # i = w[11:0], q = w[23:12]; text before the last ':' is ignored).
  @tag :capture
  @tag timeout: 1_800_000
  test "emitted Verilog == model on a real capture" do
    case System.get_env("STF_CAPTURE") do
      nil ->
        :ok

      path ->
        b64 = path |> File.read!() |> String.split(":") |> List.last() |> String.trim()
        s12 = fn v -> if v >= 2048, do: v - 4096, else: v end
        x = for <<w::little-64 <- Base.decode64!(b64)>>, do: {s12.(band(w, 0xFFF)), s12.(band(w >>> 12, 0xFFF))}
        n = String.to_integer(System.get_env("STF_N", "20000"))
        x = Enum.take(x, n)
        emin = String.to_integer(System.get_env("STF_EMIN", "1280"))
        want = model(x, emin)
        got = run_verilog(x, emin)
        IO.puts("capture: model #{length(want)} dets, verilog #{elem(got, 1)} (#{length(elem(got, 0))} pulses)")
        assert got == {want, length(want)}
    end
  end
end
