defmodule Hw.LdpcDecTest do
  use ExUnit.Case
  import Bitwise

  # ---------------------------------------------------------------------------
  # Bit-exact model: OcuSync.Phy.LdpcFixed (+ the Ldpc prototype and encoder)
  # in nervezynq/ocusync. Change together with those and scripts/gen_ldpc_dec.exs.
  # ---------------------------------------------------------------------------
  defmodule Model do
    import Bitwise

    @proto """
     0 -1 -1 -1  0  0 -1 -1  0 -1 -1  0  1  0 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1
    22  0 -1 -1 17 -1  0  0 12 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1 -1 -1 -1
     6 -1  0 -1 10 -1 -1 -1 24 -1  0 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1 -1 -1
     2 -1 -1  0 20 -1 -1 -1 25  0 -1 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1 -1
    23 -1 -1 -1  3 -1 -1 -1  0 -1  9 11 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1
    24 -1 23  1 17 -1  3 -1 10 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1
    25 -1 -1 -1  8 -1 -1 -1  7 18 -1 -1  0 -1 -1 -1 -1 -1  0  0 -1 -1 -1 -1
    13 24 -1 -1  0 -1  8 -1  6 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1 -1 -1
     7 20 -1 16 22 10 -1 -1 23 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1 -1
    11 -1 -1 -1 19 -1 -1 -1 13 -1  3 17 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1
    25 -1  8 -1 23 18 -1 14  9 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0
     3 -1 -1 -1 16 -1 -1  2 25  5 -1 -1  1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0
    """
    @z 27

    def base, do: @proto |> String.split("\n", trim: true) |> Enum.map(fn l -> l |> String.split() |> Enum.map(&String.to_integer/1) end)

    def rows do
      for brow <- base(), r <- 0..(@z - 1), do: for({h, j} <- Enum.with_index(brow), h >= 0, do: j * @z + rem(r + h, @z))
    end

    defp rot(x, 0), do: x
    defp rot(x, h), do: (x >>> h ||| x <<< (@z - h)) &&& (1 <<< @z) - 1
    defp to_blocks(bits), do: bits |> Enum.chunk_every(@z) |> Enum.map(fn bs -> bs |> Enum.with_index() |> Enum.reduce(0, fn {b, r}, a -> a ||| b <<< r end) end)
    defp from_blocks(bl), do: Enum.flat_map(bl, fn x -> for r <- 0..(@z - 1), do: x >>> r &&& 1 end)

    # Ldpc.encode/2: systematic, dual-diagonal parity.
    def encode(info) do
      b = base()
      s = info |> to_blocks() |> List.to_tuple()
      lambda = Enum.map(b, fn brow -> brow |> Enum.take(12) |> Enum.with_index() |> Enum.reduce(0, fn {-1, _}, a -> a; {h, j}, a -> bxor(a, rot(elem(s, j), h)) end) end)
      ck = b |> Enum.map(&Enum.at(&1, 12)) |> List.to_tuple()
      p0 = Enum.reduce(lambda, 0, &bxor/2)
      lam = List.to_tuple(lambda)
      term = fn i -> if elem(ck, i) >= 0, do: rot(p0, elem(ck, i)), else: 0 end
      p1 = bxor(elem(lam, 0), term.(0))
      {ps, _} = Enum.map_reduce(1..10, p1, fn i, pi -> n = elem(lam, i) |> bxor(term.(i)) |> bxor(pi); {n, n} end)
      info ++ from_blocks([p0, p1 | ps])
    end

    def decode(llr, max_iter) do
      rows = rows() |> List.to_tuple()
      l = llr |> Enum.map(&sat/1) |> List.to_tuple()
      r = rows |> Tuple.to_list() |> Enum.map(&List.to_tuple(List.duplicate(0, length(&1)))) |> List.to_tuple()
      iterate(l, r, rows, max_iter, 1)
    end

    defp iterate(l, r, rows, max_iter, it) do
      {l, r} =
        Enum.reduce(0..(tuple_size(rows) - 1), {l, r}, fn i, {l, r} ->
          cols = elem(rows, i)
          old = elem(r, i)
          t = cols |> Enum.with_index() |> Enum.map(fn {c, e} -> sat(elem(l, c) - elem(old, e)) end)

          {m1, m2, im, sg} =
            t |> Enum.with_index() |> Enum.reduce({255, 255, -1, 1}, fn {v, e}, {m1, m2, im, s} ->
              a = abs(v)
              s = if v < 0, do: -s, else: s
              cond do
                a < m1 -> {a, m1, e, s}
                a < m2 -> {m1, a, im, s}
                true -> {m1, m2, im, s}
              end
            end)

          new = t |> Enum.with_index() |> Enum.map(fn {v, e} -> mag = (3 * if(e == im, do: m2, else: m1) + 2) >>> 2; if (v < 0) != (sg < 0), do: -mag, else: mag end)
          l = Enum.zip([cols, t, new]) |> Enum.reduce(l, fn {c, tv, nv}, acc -> put_elem(acc, c, sat(tv + nv)) end)
          {l, put_elem(r, i, List.to_tuple(new))}
        end)

      hard = for i <- 0..647, do: if(elem(l, i) < 0, do: 1, else: 0)
      ht = List.to_tuple(hard)
      ok = Enum.all?(Tuple.to_list(rows), fn cols -> Enum.reduce(cols, 0, fn c, a -> bxor(a, elem(ht, c)) end) == 0 end)
      if ok or it >= max_iter, do: {ok, it, Enum.take(hard, 324)}, else: iterate(l, r, rows, max_iter, it + 1)
    end

    def sat(v), do: v |> max(-127) |> min(127)
  end

  @iverilog System.get_env("IVERILOG") ||
              System.find_executable("iverilog") ||
              (File.exists?(Path.expand("~/oss-cad-suite/bin/iverilog")) && Path.expand("~/oss-cad-suite/bin/iverilog")) || nil

  defp frame(seed, snr_db) do
    :rand.seed(:exsss, {seed, seed + 5, seed + 9})
    info = for _ <- 1..324, do: :rand.uniform(2) - 1
    cw = Model.encode(info)
    sigma = :math.sqrt(1 / (2 * 0.5 * :math.pow(10, snr_db / 10)))
    llr = Enum.map(cw, fn b -> round((1 - 2 * b + sigma * :rand.normal()) * 8) |> max(-31) |> min(31) end)
    {info, llr}
  end

  # cases: [{llr (648), max_iter}] -> [{ok, iters, info_bits}]
  def run_verilog(cases) do
    dir = Path.join(System.tmp_dir!(), "ldpc_cosim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      dut = Path.join(dir, "ldpc_dec.v")
      File.write!(dut, Hw.emit(Hw.Compile.Elaborate.elaborate(Hw.LdpcDec)))
      tb = Path.expand("support/verilog/tb_ldpc_dec.v", __DIR__)
      bin = Path.join(dir, "tb.vvp")
      {out, rc} = System.cmd(@iverilog, ["-g2012", "-o", bin, "-s", "tb", tb, dut], stderr_to_stdout: true)
      if rc != 0, do: raise("iverilog: " <> out)

      stim =
        ["#{length(cases)}\n"] ++
          Enum.flat_map(cases, fn {llr, mi} ->
            words =
              llr
              |> Enum.chunk_every(27)
              |> Enum.map(fn lanes -> lanes |> Enum.with_index() |> Enum.reduce(0, fn {v, r}, a -> a ||| (v &&& 63) <<< (6 * r) end) end)

            ["#{mi}\n" | Enum.map(words, &"#{Integer.to_string(&1, 16)}\n")]
          end)

      File.write!(Path.join(dir, "stim.txt"), stim)
      vvp = Path.join(Path.dirname(@iverilog), "vvp")
      {_, 0} = System.cmd(vvp, ["-n", bin], stderr_to_stdout: true, cd: dir)

      dir
      |> Path.join("out.txt")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reduce({[], []}, fn
        "W " <> r, {cur, acc} ->
          [b, w] = String.split(r)
          {[{String.to_integer(b), String.to_integer(w, 16)} | cur], acc}

        "N " <> r, {cur, acc} ->
          IO.puts("LdpcDec busy cycles after start: " <> r)
          {cur, acc}

        "D " <> r, {cur, acc} ->
          [ok, it] = r |> String.split() |> Enum.map(&String.to_integer/1)
          bits = cur |> Enum.sort() |> Enum.flat_map(fn {_b, w} -> for i <- 0..26, do: w >>> i &&& 1 end)
          {[], [{ok == 1, it, bits} | acc]}
      end)
      |> elem(1)
      |> Enum.reverse()
    after
      File.rm_rf!(dir)
    end
  end

  test "model: encoder output is a codeword; clean frames decode in one iteration" do
    {info, llr} = frame(1, 30.0)
    assert {true, 1, ^info} = Model.decode(llr, 8)
  end

  test "elaborates and emits" do
    assert Hw.emit(Hw.Compile.Elaborate.elaborate(Hw.LdpcDec)) =~ "module ldpc_dec"
  end

  @tag :iverilog
  @tag timeout: 1_800_000
  test "emitted Verilog == model: clean, waterfall (some fail), max_iter 1 / 3 / 8" do
    if is_nil(@iverilog), do: flunk("iverilog not found")

    cases =
      [{frame(1, 30.0), 8}, {frame(2, 3.0), 8}, {frame(3, 2.0), 8}, {frame(4, 1.5), 8}, {frame(5, 1.0), 8},
       {frame(6, 2.0), 1}, {frame(7, 2.0), 3}, {frame(8, 0.5), 4}]
      |> Enum.map(fn {{_info, llr}, mi} -> {llr, mi} end)

    want = Enum.map(cases, fn {llr, mi} -> Model.decode(llr, mi) end)
    got = run_verilog(cases)
    IO.puts("\nLdpcDec cases (ok, iters): " <> inspect(Enum.map(want, fn {ok, it, _} -> {ok, it} end)))
    assert got == want
    assert Enum.any?(want, &match?({false, _, _}, &1))
    assert Enum.any?(want, &match?({true, n, _} when n > 1, &1))
  end
end
