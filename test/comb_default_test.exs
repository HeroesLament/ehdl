defmodule CombDefaultTest do
  @moduledoc """
  In a comb block an earlier assignment is the default for everything after
  it: an `if` without `else`, a `case` selector value no arm covers, and a
  `case` arm (or catch-all) that does not assign the signal all keep it.
  That is Elixir's scoping and Verilog's `always @*` semantics.

  The elaborator used to drop the earlier assignment in comb mode and lower
  the missing arm to 0 (`s = a; if c do s = b end` became `c ? b : 0`).
  A second bug sat in both modes: an arm that does not assign a signal was
  dropped and fell into a catch-all that does (`case s do 0 -> y = 1;
  _ -> z = 2 end` gave z = 2 at s = 0); such arms now keep the value in
  effect (comb) or hold the register (sequential).

  Found 2026-11-03 in mimohalow's DcBlock saturation; an audit of every
  component in mimohalow_hdl and openocusync_hdl found it otherwise only in
  `case` arms on selector values the designs never reach.
  """
  use ExUnit.Case, async: true

  defmodule IfNoElse do
    use Hw.Component
    clock(:clk, freq: 1.0)
    input(:a, 4)
    input(:b, 4)
    input(:c, 1)
    output(:y, 4)

    comb do
      y = a

      if c == 1 do
        y = b
      end
    end
  end

  defmodule NestedIf do
    use Hw.Component
    clock(:clk, freq: 1.0)
    input(:a, 4)
    input(:b, 4)
    input(:c, 1)
    input(:d, 1)
    output(:y, 4)

    comb do
      y = a

      if c == 1 do
        if d == 1 do
          y = b
        end
      end
    end
  end

  defmodule CasePartial do
    use Hw.Component
    clock(:clk, freq: 1.0)
    input(:a, 4)
    input(:b, 4)
    input(:sel, 2)
    output(:y, 4)
    output(:z, 4)

    comb do
      y = a
      z = b

      case sel do
        0 -> y = b
        1 -> z = a
      end
    end
  end

  defmodule CaseDefaultNoAssign do
    use Hw.Component
    clock(:clk, freq: 1.0)
    input(:a, 4)
    input(:b, 4)
    input(:sel, 2)
    output(:y, 4)
    output(:z, 4)

    comb do
      y = a
      z = a

      case sel do
        0 -> y = b
        _ -> z = b
      end
    end
  end

  defmodule NoEarlierAssignment do
    use Hw.Component
    clock(:clk, freq: 1.0)
    input(:b, 4)
    input(:c, 1)
    output(:y, 4)

    comb do
      if c == 1 do
        y = b
      end
    end
  end

  # Sequential: an arm that does not assign a register holds it, also when a
  # catch-all does assign it (the arm used to be dropped and fall into the
  # catch-all).
  defmodule SeqCatchAll do
    use Hw.Component
    clock(:clk, freq: 1.0)
    input(:sel, 2)
    input(:b, 4)
    output(:r, 4)
    output(:t, 4)
    wire(:rr, 4, init: 3)
    wire(:tt, 4, init: 3)

    comb do
      r = rr
      t = tt
    end

    on :clk do
      case sel do
        0 -> tt = b
        _ -> rr = b
      end
    end
  end

  defp run(mod, inputs) do
    {:ok, sim} = Hw.Sim.start(mod)
    for {k, v} <- inputs, do: Hw.Sim.set(sim, k, v)
    Hw.Sim.tick(sim, :clk, 1)
    sim
  end

  defp get(sim, sig), do: Hw.Sim.get(sim, sig)

  test "if without else keeps the earlier assignment" do
    assert get(run(IfNoElse, a: 5, b: 9, c: 0), :y) == 5
    assert get(run(IfNoElse, a: 5, b: 9, c: 1), :y) == 9
  end

  test "nested if without else keeps the outermost earlier assignment" do
    for c <- 0..1, d <- 0..1 do
      want = if c == 1 and d == 1, do: 9, else: 5
      assert get(run(NestedIf, a: 5, b: 9, c: c, d: d), :y) == want, "c=#{c} d=#{d}"
    end
  end

  test "case: uncovered selector values and non-assigning arms keep earlier assignments" do
    for sel <- 0..3 do
      sim = run(CasePartial, a: 5, b: 9, sel: sel)
      assert get(sim, :y) == if(sel == 0, do: 9, else: 5), "y sel=#{sel}"
      assert get(sim, :z) == if(sel == 1, do: 5, else: 9), "z sel=#{sel}"
    end
  end

  test "case: a catch-all that does not assign the signal keeps the earlier assignment" do
    for sel <- 0..3 do
      sim = run(CaseDefaultNoAssign, a: 5, b: 9, sel: sel)
      assert get(sim, :y) == if(sel == 0, do: 9, else: 5), "y sel=#{sel}"
      assert get(sim, :z) == if(sel == 0, do: 5, else: 9), "z sel=#{sel}"
    end
  end

  test "sequential: a non-assigning arm holds a register a catch-all assigns" do
    {:ok, sim} = Hw.Sim.start(SeqCatchAll)
    Hw.Sim.set(sim, :b, 9)
    Hw.Sim.set(sim, :sel, 0)
    Hw.Sim.tick(sim, :clk, 1)
    assert {Hw.Sim.get(sim, :r), Hw.Sim.get(sim, :t)} == {3, 9}
    Hw.Sim.set(sim, :b, 7)
    Hw.Sim.set(sim, :sel, 2)
    Hw.Sim.tick(sim, :clk, 1)
    assert {Hw.Sim.get(sim, :r), Hw.Sim.get(sim, :t)} == {7, 9}
  end

  test "with no earlier assignment a comb signal still defaults to 0" do
    assert get(run(NoEarlierAssignment, b: 9, c: 0), :y) == 0
    assert get(run(NoEarlierAssignment, b: 9, c: 1), :y) == 9
  end

  test "the emitted Verilog selects the earlier value, not 0" do
    v = Hw.emit(Hw.Compile.Elaborate.elaborate(IfNoElse))
    refute v =~ ~r/\?\s*b\s*:\s*4'd0/
    refute v =~ ~r/\?\s*b\s*:\s*32'd0/
  end
end
