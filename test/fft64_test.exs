defmodule Hw.Fft64Test do
  use ExUnit.Case
  import Bitwise

  alias Hw.Fft64

  # ---------------------------------------------------------------------------
  # Bit-exact model: OcuSync.Phy.FftFixed (nervezynq/ocusync). Change together
  # with that and scripts/gen_fft64.exs.
  # ---------------------------------------------------------------------------
  defmodule Model do
    import Bitwise

    @tw (for m <- 0..63 do
           a = 2 * :math.pi() * m / 64
           {round(:math.cos(a) * 65536), round(-:math.sin(a) * 65536)}
         end)
        |> List.to_tuple()

    def fft(xs) when length(xs) == 64, do: level(xs, 64)

    defp level(xs, n) do
      q = div(n, 4)
      t = List.to_tuple(xs)

      groups =
        for k2 <- 0..1, k1 <- 0..1, into: %{} do
          e = k1 + 2 * k2
          s = 1 - 2 * k1

          h =
            for n3 <- 0..(q - 1) do
              {ar, ai} = elem(t, n3)
              {br, bi} = elem(t, n3 + q)
              {cr, ci} = elem(t, n3 + 2 * q)
              {dr, di} = elem(t, n3 + 3 * q)
              v = add({ar + s * cr, ai + s * ci}, negj({br + s * dr, bi + s * di}, e))
              if q > 1, do: twiddle(v, elem(@tw, rem(n3 * e * div(64, n), 64))), else: v
            end

          {e, h}
        end

      if q == 1 do
        for k <- 0..3, do: hd(groups[k])
      else
        subs = Map.new(groups, fn {e, h} -> {e, h |> level(q) |> List.to_tuple()} end)
        for k <- 0..(n - 1), do: elem(subs[rem(k, 4)], div(k, 4))
      end
    end

    defp twiddle({ar, ai}, {wr, wi}), do: {(ar * wr - ai * wi + 32768) >>> 16, (ar * wi + ai * wr + 32768) >>> 16}
    defp add({a, b}, {c, d}), do: {a + c, b + d}
    defp negj(v, 0), do: v
    defp negj({a, b}, 1), do: {b, -a}
    defp negj({a, b}, 2), do: {-a, -b}
    defp negj({a, b}, 3), do: {-b, a}

    def bitrev6(i), do: for(b <- 0..5, reduce: 0, do: (acc -> acc ||| (i >>> b &&& 1) <<< (5 - b)))

    @doc "Expected stream for `syms` (lists of 64): [{pos, bin, re, im}] in output order."
    def stream(syms) do
      syms |> Enum.with_index() |> Enum.flat_map(fn {s, si} ->
        x = s |> fft() |> List.to_tuple()
        for p <- 0..63, do: (b = bitrev6(p); {re, im} = elem(x, b); {p, b, re, im, si})
      end)
    end
  end

  @max (1 <<< 17) - 1

  defp rand_syms(n, seed, amp) do
    :rand.seed(:exsss, {seed, seed + 11, seed + 23})
    for _ <- 1..n, do: for(_ <- 1..64, do: {:rand.uniform(2 * amp + 1) - amp - 1, :rand.uniform(2 * amp + 1) - amp - 1})
  end

  defp tone(k, amp), do: for(n <- 0..63, do: {round(amp * :math.cos(2 * :math.pi() * k * n / 64)), round(amp * :math.sin(2 * :math.pi() * k * n / 64))})

  defp s26(v), do: if(v >= 1 <<< 25, do: v - (1 <<< 26), else: v)

  # Feed `syms` plus one zero symbol (flush); `gap.(t)` cycles between strobes (>= 4).
  def run_sim(syms, gap) do
    {:ok, sim} = Hw.Sim.start(Fft64)
    Hw.Sim.set(sim, :in_valid, 0)
    Hw.Sim.set(sim, :enable, 0)
    Hw.Sim.tick(sim, :clk, 2)
    Hw.Sim.set(sim, :enable, 1)

    seen = fn ->
      if Hw.Sim.get(sim, :out_valid) == 1,
        do: [{Hw.Sim.get(sim, :out_pos), Hw.Sim.get(sim, :out_bin), s26(Hw.Sim.get(sim, :out_i)), s26(Hw.Sim.get(sim, :out_q)), Hw.Sim.get(sim, :out_tag)}],
        else: []
    end

    samples = List.flatten(syms ++ [List.duplicate({0, 0}, 64)])

    out =
      samples
      |> Enum.with_index()
      |> Enum.flat_map(fn {{i, q}, t} ->
        Hw.Sim.set(sim, :in_i, i &&& 0x3FFFF)
        Hw.Sim.set(sim, :in_q, q &&& 0x3FFFF)
        Hw.Sim.set(sim, :in_tag, div(t, 64))
        Hw.Sim.set(sim, :in_valid, 1)
        Hw.Sim.tick(sim, :clk, 1)
        first = seen.()
        Hw.Sim.set(sim, :in_valid, 0)
        first ++ Enum.flat_map(1..(gap.(t) - 1), fn _ -> Hw.Sim.tick(sim, :clk, 1); seen.() end)
      end)

    tail = Enum.flat_map(1..16, fn _ -> Hw.Sim.tick(sim, :clk, 1); seen.() end)
    out ++ tail
  end

  test "model == OcuSync.Phy.FftFixed reference values (impulse, DC, tone)" do
    assert Model.fft([{5, 5} | List.duplicate({0, 0}, 63)]) == List.duplicate({5, 5}, 64)
    [x0 | rest] = Model.fft(List.duplicate({1000, -7}, 64))
    assert x0 == {64_000, -448} and Enum.all?(rest, &(&1 == {0, 0}))
    {peak, _} = tone(21, 30_000) |> Model.fft() |> Enum.with_index() |> Enum.max_by(fn {{a, b}, _} -> a * a + b * b end) |> then(fn {_, i} -> {i, 0} end)
    assert peak == 21
  end

  test "simulator == model: back-to-back symbols at 4 cycles/sample" do
    syms = rand_syms(3, 1, @max) ++ [tone(7, 100_000), List.duplicate({@max, -@max - 1}, 64)]
    want = Model.stream(syms)
    got = run_sim(syms, fn _ -> 4 end)
    assert Enum.take(got, length(want)) == want
  end

  test "simulator == model: irregular gaps between strobes" do
    syms = rand_syms(3, 2, 4096)
    want = Model.stream(syms)
    got = run_sim(syms, fn t -> 4 + rem(t * 7, 5) end)
    assert Enum.take(got, length(want)) == want
  end

  # ---------------------------------------------------------------------------
  # iverilog co-simulation
  # ---------------------------------------------------------------------------
  @iverilog System.get_env("IVERILOG") ||
              System.find_executable("iverilog") ||
              (File.exists?(Path.expand("~/oss-cad-suite/bin/iverilog")) && Path.expand("~/oss-cad-suite/bin/iverilog")) || nil

  def run_verilog(syms) do
    dir = Path.join(System.tmp_dir!(), "fft64_cosim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      dut = Path.join(dir, "fft64.v")
      File.write!(dut, Hw.emit(Hw.Compile.Elaborate.elaborate(Fft64)))
      tb = Path.expand("support/verilog/tb_fft64.v", __DIR__)
      bin = Path.join(dir, "tb.vvp")
      {out, rc} = System.cmd(@iverilog, ["-g2012", "-o", bin, "-s", "tb", tb, dut], stderr_to_stdout: true)
      if rc != 0, do: raise("iverilog: " <> out)

      samples = List.flatten(syms ++ [List.duplicate({0, 0}, 64)])
      hex = fn v -> v |> band(0x3FFFF) |> Integer.to_string(16) end
      File.write!(Path.join(dir, "stim.txt"), ["#{length(samples)}\n" | Enum.map(samples, fn {i, q} -> "#{hex.(i)} #{hex.(q)}\n" end)])
      vvp = Path.join(Path.dirname(@iverilog), "vvp")
      {_, 0} = System.cmd(vvp, ["-n", bin], stderr_to_stdout: true, cd: dir)

      dir
      |> Path.join("out.txt")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(fn l ->
        [p, b, re, im, tg] = String.split(l)
        {String.to_integer(p), String.to_integer(b), s26(String.to_integer(re, 16)), s26(String.to_integer(im, 16)), String.to_integer(tg)}
      end)
    after
      File.rm_rf!(dir)
    end
  end

  @tag :iverilog
  @tag timeout: 900_000
  test "emitted Verilog == model: random full-scale, tones, corners" do
    if is_nil(@iverilog), do: flunk("iverilog not found")
    syms = rand_syms(6, 3, @max) ++ Enum.map([1, 26, 38, 63], &tone(&1, 120_000)) ++ [List.duplicate({-@max - 1, @max}, 64)]
    want = Model.stream(syms)
    got = run_verilog(syms)
    assert Enum.take(got, length(want)) == want
  end
end
