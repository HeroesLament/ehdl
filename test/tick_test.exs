defmodule TickTest do
  use ExUnit.Case

  alias Hw.Std.Tick

  defmodule Five do
    use Hw.Component

    clock :clk, freq: 1.0
    input :rst, 1
    output :tick, 1

    instance :t, Hw.Std.Tick, CYCLES: 5, clk: :clk, rst: :rst, tick: :tick
  end

  defp sig(design, name), do: Enum.find(design.signals, &(&1.name == name))

  # Run n clocks after reset release; return the 1-based cycle numbers on
  # which tick was high.
  defp tick_cycles(n) do
    {:ok, sim} = Hw.Sim.start(Five)
    Hw.Sim.set(sim, :rst, 1)
    Hw.Sim.tick(sim, :clk, 2)
    Hw.Sim.set(sim, :rst, 0)

    cycles =
      for i <- 1..n, reduce: [] do
        acc ->
          Hw.Sim.tick(sim, :clk, 1)
          if Hw.Sim.get(sim, :tick) == 1, do: [i | acc], else: acc
      end

    Hw.Sim.stop(sim)
    Enum.reverse(cycles)
  end

  test "counter width follows CYCLES" do
    design = Hw.Compile.Elaborate.elaborate(Tick)
    # default 25_000 clocks: clog2(25_001) = 15
    assert sig(design, :cnt).width == 15
  end

  test "ticks are exactly CYCLES clocks apart" do
    cycles = tick_cycles(40)
    assert length(cycles) >= 6, "expected several ticks, got #{inspect(cycles)}"
    assert cycles |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end) |> Enum.uniq() == [5]
  end

  test "tick is a single-cycle strobe" do
    cycles = tick_cycles(40)
    assert cycles == Enum.uniq(cycles)
    assert Enum.all?(Enum.chunk_every(cycles, 2, 1, :discard), fn [a, b] -> b - a > 1 end)
  end

  test "config/2 converts every unit to clocks" do
    assert Tick.config(25_000_000, ms: 10) == [CYCLES: 250_000]
    assert Tick.config(25_000_000, us: 40) == [CYCLES: 1_000]
    assert Tick.config(25_000_000, ns: 80) == [CYCLES: 2]
    assert Tick.config(25_000_000, s: 1) == [CYCLES: 25_000_000]
  end

  test "a bare integer period is milliseconds" do
    assert Tick.config(25_000_000, 10) == Tick.config(25_000_000, ms: 10)
  end

  test "config/2 rejects a period finer than the clock, and says the step" do
    e = assert_raise ArgumentError, fn -> Tick.config(25_000_000, ns: 7) end
    assert e.message =~ "40.0 ns"
    assert_raise ArgumentError, ~r/not a whole number/, fn -> Tick.config(25_000_000, ns: 50) end
  end

  test "config/2 rejects too-short periods and unknown units" do
    assert_raise ArgumentError, ~r/at least 2/, fn -> Tick.config(1_000, ms: 1) end
    assert_raise ArgumentError, ~r/unknown unit/, fn -> Tick.config(25_000_000, min: 1) end
  end

  test "emits clocked verilog" do
    verilog = Hw.emit(Hw.Compile.Elaborate.elaborate(Tick))
    assert String.contains?(verilog, "always @(posedge")
  end
end
