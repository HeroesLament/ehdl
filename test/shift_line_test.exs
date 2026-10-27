defmodule Hw.ShiftLineTest.Plain do
  use Hw.Component
  clock :clk, reset_style: :none
  input :en, 1
  input :clr, 1
  input :x, 8
  output :y, 8

  wire :s0, 8, init: 0
  wire :s1, 8, init: 0
  wire :s2, 8, init: 0
  wire :s3, 8, init: 0
  wire :s4, 8, init: 0
  wire :s5, 8, init: 0
  wire :s6, 8, init: 0
  wire :s7, 8, init: 0
  wire :s8, 8, init: 0
  wire :s9, 8, init: 0
  wire :s10, 8, init: 0
  wire :s11, 8, init: 0
  wire :s12, 8, init: 0
  wire :s13, 8, init: 0
  wire :s14, 8, init: 0
  wire :s15, 8, init: 0

  comb do
    y = s15

  end

  on :clk do
    if en do
      s0 = x
      s1 = s0
      s2 = s1
      s3 = s2
      s4 = s3
      s5 = s4
      s6 = s5
      s7 = s6
      s8 = s7
      s9 = s8
      s10 = s9
      s11 = s10
      s12 = s11
      s13 = s12
      s14 = s13
      s15 = s14
    end

  end
end

defmodule Hw.ShiftLineTest.Tap do
  use Hw.Component
  clock :clk, reset_style: :none
  input :en, 1
  input :clr, 1
  input :x, 8
  output :y, 8
  output :z, 8
  wire :s0, 8, init: 0
  wire :s1, 8, init: 0
  wire :s2, 8, init: 0
  wire :s3, 8, init: 0
  wire :s4, 8, init: 0
  wire :s5, 8, init: 0
  wire :s6, 8, init: 0
  wire :s7, 8, init: 0
  wire :s8, 8, init: 0
  wire :s9, 8, init: 0
  wire :s10, 8, init: 0
  wire :s11, 8, init: 0
  wire :s12, 8, init: 0
  wire :s13, 8, init: 0
  wire :s14, 8, init: 0
  wire :s15, 8, init: 0

  comb do
    y = s15
    z = s7
  end

  on :clk do
    if en do
      s0 = x
      s1 = s0
      s2 = s1
      s3 = s2
      s4 = s3
      s5 = s4
      s6 = s5
      s7 = s6
      s8 = s7
      s9 = s8
      s10 = s9
      s11 = s10
      s12 = s11
      s13 = s12
      s14 = s13
      s15 = s14
    end

  end
end

defmodule Hw.ShiftLineTest.Clear do
  use Hw.Component
  clock :clk, reset_style: :none
  input :en, 1
  input :clr, 1
  input :x, 8
  output :y, 8

  wire :s0, 8, init: 0
  wire :s1, 8, init: 0
  wire :s2, 8, init: 0
  wire :s3, 8, init: 0
  wire :s4, 8, init: 0
  wire :s5, 8, init: 0
  wire :s6, 8, init: 0
  wire :s7, 8, init: 0
  wire :s8, 8, init: 0
  wire :s9, 8, init: 0
  wire :s10, 8, init: 0
  wire :s11, 8, init: 0
  wire :s12, 8, init: 0
  wire :s13, 8, init: 0
  wire :s14, 8, init: 0
  wire :s15, 8, init: 0

  comb do
    y = s15

  end

  on :clk do
    if en do
      s0 = x
      s1 = s0
      s2 = s1
      s3 = s2
      s4 = s3
      s5 = s4
      s6 = s5
      s7 = s6
      s8 = s7
      s9 = s8
      s10 = s9
      s11 = s10
      s12 = s11
      s13 = s12
      s14 = s13
      s15 = s14
    end

    if clr do
      s3 = 0
    end
  end
end

defmodule Hw.ShiftLineTest do
  use ExUnit.Case, async: true

  alias Hw.Analysis.Rules.ShiftLine
  alias __MODULE__.{Clear, Plain, Tap}

  defp ir(mod), do: Hw.Compile.Elaborate.elaborate(mod)

  test "a plain 16-deep enable line maps to SRLs: not reported" do
    assert ShiftLine.run(ir(Plain)) == []
  end

  test "a middle tap keeps it in flip-flops" do
    assert [d] = ShiftLine.run(ir(Tap))
    assert d.severity == :hint
    assert d.context.depth == 16
    assert d.context.ffs == 128
    assert d.context.first == :s0
    assert d.context.last == :s15
    assert d.context.blockers == ["1 middle tap(s)"]
  end

  test "a clear on one stage keeps it in flip-flops" do
    assert [d] = ShiftLine.run(ir(Clear))
    assert d.context.depth == 16
    assert d.context.blockers == ["reset"]
  end
end
