defmodule Hw.TraceExUnitTest do
  use ExUnit.Case, async: true

  import Hw.Trace.ExUnit

  alias Hw.Trace

  # A trace where :sig holds 5 for cycles 0..4, then changes to 9 at cycle 5.
  defp trace do
    specs = [{:sig, %{width: 4, init: 5}}, {:flag, %{width: 1, init: 0}}]

    Enum.reduce(0..7, Trace.new(specs), fn c, t ->
      sig = if c >= 5, do: 9, else: 5
      flag = if c in 2..4, do: 1, else: 0
      Trace.apply_snapshot(t, %{sig: sig, flag: flag}, c * 100)
    end)
  end

  test "assert_at passes and fails correctly" do
    assert_at(trace(), :sig, cycle: 0, value: 5)
    assert_at(trace(), :sig, cycle: 5, value: 9)

    assert_raise ExUnit.AssertionError, fn ->
      assert_at(trace(), :sig, cycle: 0, value: 99)
    end
  end

  test "assert_stable passes over a stable window" do
    assert_stable(trace(), :sig, value: 5, during: 0..4)
  end

  test "assert_stable reports the ABSOLUTE cycle on failure (the fixed bug)" do
    # Window 3..6: stable at 5 for 3,4 then changes to 9 at cycle 5.
    # The OLD Hw.Waveform code numbered from range.first+1 and would misreport
    # this. The fix reports the true absolute cycle: 5.
    err =
      assert_raise RuntimeError, fn ->
        assert_stable(trace(), :sig, during: 3..6)
      end

    assert err.message =~ "at cycle 5"
    refute err.message =~ "at cycle 4"
  end

  test "assert_sequence checks consecutive cycles" do
    assert_sequence(trace(), :sig, [5, 5, 5, 5, 5, 9, 9, 9])
    assert_sequence(trace(), :sig, [5, 9], from: 4)

    assert_raise RuntimeError, ~r/sequence mismatch/, fn ->
      assert_sequence(trace(), :sig, [5, 5, 5], from: 4)
    end
  end

  test "assert_reaches finds a value by a deadline" do
    assert_reaches(trace(), :sig, 9, by: 5)

    assert_raise RuntimeError, ~r/never reached/, fn ->
      assert_reaches(trace(), :sig, 9, by: 4)
    end
  end

  test "assertions accept hierarchical / string references" do
    specs = [{:sie_rx_state, %{width: 3, init: 0}}]
    t = Trace.new(specs) |> Trace.apply_snapshot(%{sie_rx_state: 2}, 0)

    assert_at(t, "sie.rx_state", cycle: 0, value: 2)
    assert_at(t, {[:sie], :rx_state}, cycle: 0, value: 2)
  end
end
