defmodule MemWriteCaseTest do
  @moduledoc """
  A memory write inside a case arm is enabled by that arm alone (first
  match wins), not by every arm of the case: `m[a] = d` under `1 ->` must
  not write when the subject is 0, 2 or 3. Checked on the emitted Verilog
  (Hw.Sim has no memories).
  """
  use ExUnit.Case, async: true

  @iverilog System.find_executable("iverilog")

  defmodule ArmWrite do
    use Hw.Component
    clock :clk, freq: 1.0
    input :we, 1
    input :op, 2
    input :a, 2
    input :d, 8
    input :ra, 2
    output :q, 8
    memory :m, width: 8, depth: 4
    wire :cnt, 8, init: 0

    comb do
      q = m[ra]
    end

    on :clk do
      if we == 1 do
        case op do
          1 ->
            m[a] = d

          2 ->
            m[a] = d + 1

          _ ->
            cnt = cnt + 1
        end
      end
    end
  end

  # The same under binary patterns: a literal segment and a wildcard, then
  # a catch-all. `<<1::1, _::1>>` (op 2 or 3) writes d, `<<0::1, 1::1>>`
  # (op 1) writes d + 1, op 0 falls to the counter.
  defmodule BinArmWrite do
    use Hw.Component
    clock :clk, freq: 1.0
    input :we, 1
    input :op, 2
    input :a, 2
    input :d, 8
    input :ra, 2
    output :q, 8
    memory :m, width: 8, depth: 4
    wire :cnt, 8, init: 0

    comb do
      q = m[ra]
    end

    on :clk do
      if we == 1 do
        hdl_case <<op::2>> do
          <<1::1, _::1>> ->
            m[a] = d

          <<0::1, 1::1>> ->
            m[a] = d + 1

          <<_::2>> ->
            cnt = cnt + 1
        end
      end
    end
  end

  @tag :iverilog
  test "only the matching arm writes; other subjects leave the memory alone" do
    if is_nil(@iverilog), do: flunk("iverilog not found")
    dir = Path.join(System.tmp_dir!(), "mem_write_case_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      dut = Path.join(dir, "dut.v")
      v = Hw.emit(Hw.Compile.Elaborate.elaborate(ArmWrite))
      File.write!(dut, v)
      [_, name] = Regex.run(~r/module\s+(\w+)/, v)
      tb = Path.join(dir, "tb.v")

      # writes: (op 1, a 0, 10) (op 2, a 1, 20 -> 21) (op 0, a 0, 99)
      # (op 3, a 1, 98) (we 0, op 1, a 2, 97); then read 0..2
      File.write!(tb, """
      `timescale 1ns/1ps
      module tb;
        reg clk = 0, we = 0; reg [1:0] op = 0, a = 0, ra = 0; reg [7:0] d = 0; wire [7:0] q;
        #{name} dut(.clk(clk), .we(we), .op(op), .a(a), .d(d), .ra(ra), .q(q));
        task w(input e, input [1:0] o, input [1:0] ad, input [7:0] dd);
          begin we = e; op = o; a = ad; d = dd; #5 clk = 1; #5 clk = 0; end
        endtask
        initial begin
          w(1, 0, 2, 55);
          w(1, 1, 0, 10); w(1, 2, 1, 20); w(1, 0, 0, 99); w(1, 3, 1, 98); w(0, 1, 2, 97);
          ra = 0; #1 $display("R %0d", q);
          ra = 1; #1 $display("R %0d", q);
          ra = 2; #1 $display("R %0d", q);
          $finish;
        end
      endmodule
      """)

      bin = Path.join(dir, "tb.vvp")
      {out, rc} = System.cmd(@iverilog, ["-g2012", "-o", bin, "-s", "tb", tb, dut], stderr_to_stdout: true)
      assert rc == 0, out
      vvp = Path.join(Path.dirname(@iverilog), "vvp")
      {out, 0} = System.cmd(vvp, ["-n", bin], stderr_to_stdout: true, cd: dir)
      got = for "R " <> r <- String.split(out, "\n", trim: true), do: r

      # address 2 never written: x (uninitialised), not 97 or 55
      assert Enum.take(got, 2) == ["10", "21"], out
      refute Enum.at(got, 2) in ["97", "55"], out
    after
      File.rm_rf!(dir)
    end
  end

  @tag :iverilog
  test "binary-pattern arms write only on their own match" do
    if is_nil(@iverilog), do: flunk("iverilog not found")
    dir = Path.join(System.tmp_dir!(), "mem_write_bcase_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      dut = Path.join(dir, "dut.v")
      v = Hw.emit(Hw.Compile.Elaborate.elaborate(BinArmWrite))
      File.write!(dut, v)
      [_, name] = Regex.run(~r/module\s+(\w+)/, v)
      tb = Path.join(dir, "tb.v")

      # (op 2, a 0, 10) -> m[0]=10; (op 1, a 1, 20) -> m[1]=21;
      # (op 3, a 3, 30) -> m[3]=30; (op 0, a 2, 99) and (we 0, op 2, a 2, 97)
      # must not write m[2].
      File.write!(tb, """
      `timescale 1ns/1ps
      module tb;
        reg clk = 0, we = 0; reg [1:0] op = 0, a = 0, ra = 0; reg [7:0] d = 0; wire [7:0] q;
        #{name} dut(.clk(clk), .we(we), .op(op), .a(a), .d(d), .ra(ra), .q(q));
        task w(input e, input [1:0] o, input [1:0] ad, input [7:0] dd);
          begin we = e; op = o; a = ad; d = dd; #5 clk = 1; #5 clk = 0; end
        endtask
        initial begin
          w(1, 2, 0, 10); w(1, 1, 1, 20); w(1, 3, 3, 30); w(1, 0, 2, 99); w(0, 2, 2, 97);
          ra = 0; #1 $display("R %0d", q);
          ra = 1; #1 $display("R %0d", q);
          ra = 3; #1 $display("R %0d", q);
          ra = 2; #1 $display("R %0d", q);
          $finish;
        end
      endmodule
      """)

      bin = Path.join(dir, "tb.vvp")
      {out, rc} = System.cmd(@iverilog, ["-g2012", "-o", bin, "-s", "tb", tb, dut], stderr_to_stdout: true)
      assert rc == 0, out
      vvp = Path.join(Path.dirname(@iverilog), "vvp")
      {out, 0} = System.cmd(vvp, ["-n", bin], stderr_to_stdout: true, cd: dir)
      got = for "R " <> r <- String.split(out, "\n", trim: true), do: r

      assert Enum.take(got, 3) == ["10", "21", "30"], out
      refute Enum.at(got, 3) in ["99", "100", "97"], out
    after
      File.rm_rf!(dir)
    end
  end
end
