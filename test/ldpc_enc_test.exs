defmodule Hw.LdpcEncTest do
  use ExUnit.Case
  import Bitwise

  @iverilog System.get_env("IVERILOG") || System.find_executable("iverilog")

  # Same prototype as scripts/gen_ldpc_enc.exs and OcuSync.Phy.Ldpc.
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

  defp base, do: @proto |> String.split("\n", trim: true) |> Enum.map(fn l -> l |> String.split() |> Enum.map(&String.to_integer/1) end)

  defp rot(x, 0), do: x
  defp rot(x, h), do: (x >>> h ||| x <<< (27 - h)) &&& (1 <<< 27) - 1

  # OcuSync.Phy.Ldpc.encode/2 on blocks: 12 info blocks -> 24 codeword blocks.
  def encode(s) do
    b = base()
    lam = Enum.map(b, fn row -> row |> Enum.take(12) |> Enum.with_index() |> Enum.reduce(0, fn {-1, _}, a -> a; {h, j}, a -> bxor(a, rot(Enum.at(s, j), h)) end) end)
    p0 = Enum.reduce(lam, 0, &bxor/2)
    term = fn i -> case Enum.at(Enum.at(b, i), 12) do -1 -> 0; h -> rot(p0, h) end end
    p1 = bxor(Enum.at(lam, 0), term.(0))
    {ps, _} = Enum.map_reduce(1..10, p1, fn i, pi -> n = Enum.at(lam, i) |> bxor(term.(i)) |> bxor(pi); {n, n} end)
    s ++ [p0, p1 | ps]
  end

  # Every parity check of H is satisfied (independent of the encoder algebra).
  defp checks_ok?(cw) do
    Enum.all?(base(), fn row ->
      row |> Enum.with_index() |> Enum.reduce(0, fn {-1, _}, a -> a; {h, j}, a -> bxor(a, rot(Enum.at(cw, j), h)) end) == 0
    end)
  end

  test "model codewords satisfy every parity check" do
    for seed <- 1..20 do
      :rand.seed(:exsss, {seed, 7, 11})
      s = for _ <- 1..12, do: :rand.uniform(1 <<< 27) - 1
      assert checks_ok?(encode(s))
    end
  end

  @tag :iverilog
  test "emitted Verilog == model, back-to-back and gapped codewords" do
    if is_nil(@iverilog), do: flunk("iverilog not found")
    cws = for seed <- 1..4 do
      :rand.seed(:exsss, {seed, 3, 5})
      for _ <- 1..12, do: :rand.uniform(1 <<< 27) - 1
    end
    want = Enum.map(cws, &encode/1)

    dir = Path.join(System.tmp_dir!(), "ldpc_enc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      dut = Path.join(dir, "dut.v")
      File.write!(dut, Hw.emit(Hw.Compile.Elaborate.elaborate(Hw.LdpcEnc)))
      File.write!(Path.join(dir, "in.hex"), cws |> List.flatten() |> Enum.map_join("\n", &Integer.to_string(&1, 16)))
      tb = Path.join(dir, "tb.v")

      File.write!(tb, """
      `timescale 1ns/1ps
      module tb;
        reg clk = 0, enable = 0, clear = 0, in_v = 0; reg [26:0] in_blk = 0;
        wire in_ready, out_v; wire [26:0] out_blk; wire [4:0] out_idx;
        ldpc_enc dut(.clk(clk), .enable(enable), .clear(clear), .in_v(in_v), .in_blk(in_blk),
          .in_ready(in_ready), .out_v(out_v), .out_blk(out_blk), .out_idx(out_idx));
        reg [26:0] mem [0:47];
        integer fo, n, k, cyc;
        task tick; begin #5 clk = 1; #5 clk = 0; cyc = cyc + 1; if (out_v) $fdisplay(fo, "O %0d %h %0d", out_idx, out_blk, cyc); end endtask
        initial begin
          $readmemh("in.hex", mem); fo = $fopen("out.txt", "w"); cyc = 0;
          tick; enable = 1; tick;
          for (n = 0; n < 48; n = n + 1) begin
            while (!in_ready) tick;
            in_v = 1; in_blk = mem[n]; tick; in_v = 0;
            // codewords 2 and 3 gapped, 0 and 1 back to back
            if (n >= 24) for (k = 0; k < (n % 5); k = k + 1) tick;
          end
          for (k = 0; k < 200; k = k + 1) tick;
          $fclose(fo); $finish;
        end
      endmodule
      """)

      bin = Path.join(dir, "tb.vvp")
      {out, rc} = System.cmd(@iverilog, ["-g2012", "-o", bin, "-s", "tb", tb, dut], stderr_to_stdout: true)
      assert rc == 0, out
      vvp = Path.join(Path.dirname(@iverilog), "vvp")
      {_, 0} = System.cmd(vvp, ["-n", bin], stderr_to_stdout: true, cd: dir)

      got =
        for "O " <> r <- dir |> Path.join("out.txt") |> File.read!() |> String.split("\n", trim: true) do
          [i, b, c] = String.split(r)
          {String.to_integer(i), String.to_integer(b, 16), String.to_integer(c)}
        end

      assert Enum.map(got, &elem(&1, 0)) == List.flatten(List.duplicate(Enum.to_list(0..23), 4))
      assert got |> Enum.map(&elem(&1, 1)) |> Enum.chunk_every(24) == want
      # Latency: 12th info block in to last parity block out.
      [{_, _, c11}, {_, _, c23}] = got |> Enum.take(24) |> then(&[Enum.at(&1, 11), Enum.at(&1, 23)])
      IO.puts("LdpcEnc block 11 -> block 23: #{c23 - c11} cycles")
    after
      File.rm_rf!(dir)
    end
  end
end
