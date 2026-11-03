defmodule Hw.RotTabTest do
  use ExUnit.Case
  import Bitwise

  @iverilog System.find_executable("iverilog")

  defp sx(v, w), do: if(v >= 1 <<< (w - 1), do: v - (1 <<< w), else: v)

  defp stimulus do
    :rand.seed(:exsss, {4, 5, 6})

    for n <- 1..400 do
      x = :rand.uniform(1 <<< 24) - (1 <<< 23)
      y = :rand.uniform(1 <<< 24) - (1 <<< 23)
      # corners: quadrant edges and r == 0
      a = if rem(n, 7) == 0, do: Enum.random([0, 16384, -16384, -32768, 8, -8, 16]), else: :rand.uniform(65536) - 32769
      {x, y, a, n}
    end
  end

  test "model tracks K * rotation within the 12-bit phase step" do
    :rand.seed(:exsss, {1, 2, 3})
    k = Hw.RotTab.gain()

    for _ <- 1..5000 do
      x = :rand.uniform(1 <<< 24) - (1 <<< 23)
      y = :rand.uniform(1 <<< 24) - (1 <<< 23)
      a = :rand.uniform(65536) - 32769
      {gx, gy} = Hw.RotTab.model(x, y, a)
      t = 2 * :math.pi() * a / 65536
      fx = k * (x * :math.cos(t) - y * :math.sin(t))
      fy = k * (x * :math.sin(t) + y * :math.cos(t))
      mag = k * :math.sqrt(x * x + y * y)
      tol = mag * 2 * :math.pi() / 8192 + mag * 2.0e-5 + 2
      assert abs(gx - fx) <= tol and abs(gy - fy) <= tol, inspect({x, y, a, gx, fx, gy, fy})
    end
  end

  @tag :iverilog
  test "emitted Verilog == model, one input per cycle, latency 2" do
    if is_nil(@iverilog), do: flunk("iverilog not found")
    ins = stimulus()
    dir = Path.join(System.tmp_dir!(), "rot_tab_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      dut = Path.join(dir, "dut.v")
      File.write!(dut, Hw.emit(Hw.Compile.Elaborate.elaborate(Hw.RotTab)))
      tb = Path.join(dir, "tb.v")

      File.write!(tb, """
      `timescale 1ns/1ps
      module tb;
        reg clk = 0, in_v = 0; reg [24:0] x = 0, y = 0; reg [15:0] a = 0; reg [47:0] tag = 0;
        wire out_v; wire [26:0] xo, yo; wire [47:0] out_tag;
        rot_tab dut(.clk(clk), .in_v(in_v), .x(x), .y(y), .a(a), .tag(tag), .out_v(out_v), .xo(xo), .yo(yo), .out_tag(out_tag));
        integer fi, fo, rc, n;
        task tick; begin #5 clk = 1; #5 clk = 0; if (out_v) $fdisplay(fo, "%0d %h %h", out_tag, xo, yo); end endtask
        initial begin
          fi = $fopen("stim.txt", "r"); fo = $fopen("out.txt", "w");
          tick; tick;
          while (!$feof(fi)) begin
            rc = $fscanf(fi, "%h %h %h %h\\n", x, y, a, tag);
            if (rc == 4) begin in_v = 1; tick; end
          end
          in_v = 0; tick; tick; tick;
          $fclose(fo); $finish;
        end
      endmodule
      """)

      File.write!(Path.join(dir, "stim.txt"),
        Enum.map_join(ins, fn {x, y, a, n} ->
          :io_lib.format("~7.16.0b ~7.16.0b ~4.16.0b ~8.16.0b~n", [x &&& 0x1FFFFFF, y &&& 0x1FFFFFF, a &&& 0xFFFF, n]) |> IO.iodata_to_binary()
        end))

      bin = Path.join(dir, "tb.vvp")
      {out, rc} = System.cmd(@iverilog, ["-g2012", "-o", bin, "-s", "tb", tb, dut], stderr_to_stdout: true)
      assert rc == 0, out
      vvp = Path.join(Path.dirname(@iverilog), "vvp")
      {_, 0} = System.cmd(vvp, ["-n", bin], stderr_to_stdout: true, cd: dir)

      got =
        dir
        |> Path.join("out.txt")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(fn l ->
          [t, xo, yo] = String.split(l)
          {String.to_integer(t), {sx(String.to_integer(xo, 16), 27), sx(String.to_integer(yo, 16), 27)}}
        end)

      want = for {x, y, a, n} <- ins, do: {n, Hw.RotTab.model(x, y, a)}
      bad = got |> Enum.zip(want) |> Enum.reject(fn {g, w} -> g == w end) |> Enum.take(3)
      assert {length(got), bad} == {length(want), []}
    after
      File.rm_rf!(dir)
    end
  end
end
