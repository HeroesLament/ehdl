defmodule Hw.TraceWindowQueryTest do
  use ExUnit.Case, async: true

  import Hw.Trace.Query

  alias Hw.Trace

  # A trace with 8 samples at ps 0,100,...,700. We mark two phases:
  #   :phase_a over ps 100..300  (samples at index 1,2,3)
  #   :phase_b over ps 400..600  (samples at index 4,5,6)
  # sig goes 0,1,2,3,4,5,6,7 (== index), so it's easy to reason about.
  defp trace do
    specs = [{:sig, %{width: 4, init: 0}}, {:cdc_dev_state, %{width: 2, init: 0}}]

    base =
      Enum.reduce(0..7, Trace.new(specs), fn i, t ->
        dev = if i >= 5, do: 2, else: 0
        Trace.apply_snapshot(t, %{sig: i, cdc_dev_state: dev}, i * 100)
      end)

    base
    |> Trace.begin_tr(:phase_a, 100)
    |> Trace.end_tr(:phase_a, 300)
    |> Trace.begin_tr(:phase_b, 400)
    |> Trace.end_tr(:phase_b, 600)
  end

  describe "timeline window:" do
    test "restricts samples to the window's ps bounds" do
      tl = timeline(trace(), window: :phase_a)
      assert Enum.map(tl, & &1.time_ps) == [100, 200, 300]
      assert Enum.map(tl, & &1.index) == [1, 2, 3]
    end

    test "explicit from:/to: overrides window:" do
      tl = timeline(trace(), window: :phase_a, from: 500)
      # from: 500 wins for the lower bound; window's to: (300) is overridden too
      # since to: defaults from window only when not given — here to: is absent so
      # window's 300 applies as upper bound, giving an empty range.
      assert Enum.map(tl, & &1.time_ps) == []
    end
  end

  describe "find_when window: (verbs inherit it through timeline)" do
    test "condition matches only inside the window" do
      # sig == 5 happens at index 5 (ps 500), which is in phase_b, not phase_a
      assert find_when(trace(), [window: :phase_a], sig: 5) == []
      assert find_when(trace(), [window: :phase_b], sig: 5) |> Enum.map(& &1.index) == [5]
    end
  end

  describe "transitions window:" do
    test "only edges within the window are returned" do
      # sig changes every sample; within phase_a (idx 1,2,3) there are 2 edges
      trs = transitions(trace(), [window: :phase_a], :sig)
      assert Enum.map(trs, & &1.index) == [2, 3]
    end
  end

  describe "diff window:" do
    test "diff :first/:last is scoped to the window" do
      d = diff(trace(), [window: :phase_b], :first, :last)
      # phase_b spans idx 4..6: sig 4→6, and cdc_dev_state 0→2 (flips at idx 5)
      assert d[{[:top], :sig}] == {4, 6}
      assert d[{[:cdc], :dev_state}] == {0, 2}
    end
  end

  describe "snapshot window:" do
    test "snapshot :last within a window" do
      s = snapshot(trace(), [window: :phase_a], :last)
      assert s[{[:top], :sig}] == 3
    end
  end

  describe "window resolution edge cases" do
    test "unknown window label raises" do
      assert_raise ArgumentError, ~r/unknown window/, fn ->
        timeline(trace(), window: :nonexistent)
      end
    end

    test "open span (no end_tr) runs to end of trace" do
      t = trace() |> Trace.begin_tr(:tail, 500)
      tl = timeline(t, window: :tail)
      # from 500 to end (700): indexes 5,6,7
      assert Enum.map(tl, & &1.time_ps) == [500, 600, 700]
    end

    test "a %Window{} struct works directly as window:" do
      t = trace()
      w = Trace.window(t, :phase_b)
      assert timeline(t, window: w) |> Enum.map(& &1.index) == [4, 5, 6]
    end
  end
end
