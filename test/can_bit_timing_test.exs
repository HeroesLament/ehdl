defmodule CanBitTimingTest do
  use ExUnit.Case

  alias Hw.CAN.BitTiming

  defp sig(design, name), do: Enum.find(design.signals, &(&1.name == name))

  test "elaborates and produces a clocked design" do
    design = Hw.Compile.Elaborate.elaborate(BitTiming)

    assert sig(design, :sample_point).width == 1
    assert sig(design, :write_point).width == 1
    assert sig(design, :sampled_bit).width == 1
    assert sig(design, :tq_ctr).width == 8

    verilog = Hw.emit(design)
    assert String.contains?(verilog, "always @(posedge")
  end

  test "default parameters are 1 Mbit/s at 48 MHz with a 75% sample point" do
    defaults = [TQ_CLOCKS: 6, PROP_SEG: 2, PHASE_SEG1: 3, PHASE_SEG2: 2, SJW: 2]

    assert BitTiming.bitrate(48_000_000, defaults) == 1_000_000
    assert BitTiming.sample_point_pct(defaults) == 75.0
  end

  test "config/2 hits the requested bit rate exactly" do
    for rate <- [125_000, 250_000, 500_000, 1_000_000] do
      opts = BitTiming.config(48_000_000, rate)
      assert is_list(opts), "no config found for #{rate}"
      assert BitTiming.bitrate(48_000_000, opts) == rate
    end
  end

  test "config/2 follows the CiA sample-point recommendation" do
    # 87.5% at and below 500 kbit/s, 75% at 1 Mbit/s.
    assert BitTiming.sample_point_pct(BitTiming.config(48_000_000, 500_000)) == 87.5
    assert BitTiming.sample_point_pct(BitTiming.config(48_000_000, 1_000_000)) == 75.0
  end

  test "config/2 produces legal segment counts" do
    for rate <- [125_000, 250_000, 500_000, 1_000_000] do
      opts = BitTiming.config(48_000_000, rate)
      prop = opts[:PROP_SEG]
      ps1 = opts[:PHASE_SEG1]
      ps2 = opts[:PHASE_SEG2]
      total = 1 + prop + ps1 + ps2

      assert total >= 8 and total <= 25, "#{rate}: #{total} TQ out of range"
      assert ps2 >= 1, "#{rate}: phase segment 2 must be at least 1 TQ"
      assert opts[:SJW] <= ps2, "#{rate}: SJW may not exceed phase segment 2"
      assert opts[:SJW] <= 4, "#{rate}: SJW is capped at 4 TQ"
    end
  end

  test "a bit rate the clock cannot divide exactly is refused, not rounded" do
    # 48 MHz / 33 kbit/s has no whole-TQ split.
    assert BitTiming.config(48_000_000, 33_000) == {:error, :no_exact_divisor}
  end

  test "resync jump width never exceeds either phase segment" do
    opts = BitTiming.config(48_000_000, 500_000)
    assert opts[:SJW] <= opts[:PHASE_SEG1]
    assert opts[:SJW] <= opts[:PHASE_SEG2]
  end
end
