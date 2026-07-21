defmodule Hw.TraceQueryTest do
  use ExUnit.Case, async: true

  alias Hw.Trace
  alias Hw.Trace.Query

  # Fixture: a top-level LED port + two SIE entity registers, driven over 5
  # samples so we get real transitions to query.
  defp fixture do
    specs = [
      {:led, %{width: 1, init: 0}},
      {:sie_rx_state, %{width: 3, init: 0}},
      {:sie_tx_state, %{width: 2, init: 0}}
    ]

    Trace.new(specs)
    |> Trace.apply_snapshot(%{led: 0, sie_rx_state: 0, sie_tx_state: 0}, 0)
    |> Trace.apply_snapshot(%{led: 0, sie_rx_state: 1, sie_tx_state: 0}, 100)
    |> Trace.apply_snapshot(%{led: 1, sie_rx_state: 2, sie_tx_state: 0}, 200)
    |> Trace.apply_snapshot(%{led: 1, sie_rx_state: 2, sie_tx_state: 3}, 300)
    |> Trace.apply_snapshot(%{led: 0, sie_rx_state: 0, sie_tx_state: 0}, 400)
  end

  describe "timeline/2" do
    test "unscoped returns full addressed state per sample" do
      tl = Query.timeline(fixture())
      assert length(tl) == 5
      first = List.first(tl)
      assert first.index == 0
      assert first.time_ps == 0
      assert first.state[{[:top], :led}] == 0
      assert first.state[{[:sie], :rx_state}] == 0
    end

    test "scoped projects to bare leaves of that scope only" do
      tl = Query.timeline(fixture(), scope: :sie)
      s2 = Enum.at(tl, 2).state
      # only sie leaves, keyed by bare name
      assert s2 == %{rx_state: 2, tx_state: 0}
      refute Map.has_key?(s2, :led)
    end

    test "time window filters by ps" do
      tl = Query.timeline(fixture(), from: 100, to: 300)
      assert Enum.map(tl, & &1.time_ps) == [100, 200, 300]
    end
  end

  describe "find_when/3" do
    test "scoped keyword conditions key on leaves" do
      hits = Query.find_when(fixture(), [scope: :sie], rx_state: 2, tx_state: 0)
      assert Enum.map(hits, & &1.index) == [2]
    end

    test "unscoped can query a top-level PORT (new capability)" do
      # This is the headline win: Hw.Simtrace could never see :led.
      hits = Query.find_when(fixture(), [], "top.led": 1)
      assert Enum.map(hits, & &1.time_ps) == [200, 300]
    end

    test "function condition over the full addressed state" do
      hits =
        Query.find_when(fixture(), [], fn s ->
          s[{[:sie], :rx_state}] == 2 and s[{[:top], :led}] == 1
        end)

      assert Enum.map(hits, & &1.index) == [2, 3]
    end
  end

  describe "first/3" do
    test "returns the first matching entry or nil" do
      assert Query.first(fixture(), [scope: :sie], tx_state: 3).index == 3
      assert Query.first(fixture(), [scope: :sie], tx_state: 99) == nil
    end
  end

  describe "transitions/3" do
    test "scoped leaf transitions with index+time+from/to" do
      trs = Query.transitions(fixture(), [scope: :sie], :rx_state)

      assert trs == [
               %{index: 1, time_ps: 100, from: 0, to: 1},
               %{index: 2, time_ps: 200, from: 1, to: 2},
               %{index: 4, time_ps: 400, from: 2, to: 0}
             ]
    end

    test "port transitions (unscoped)" do
      trs = Query.transitions(fixture(), [], :led)
      assert Enum.map(trs, &{&1.from, &1.to}) == [{0, 1}, {1, 0}]
    end
  end

  describe "diff/4" do
    test "between two index points, unscoped, addressed keys" do
      d = Query.diff(fixture(), [], {:index, 0}, {:index, 3})
      assert d[{[:top], :led}] == {0, 1}
      assert d[{[:sie], :rx_state}] == {0, 2}
      assert d[{[:sie], :tx_state}] == {0, 3}
    end

    test "scoped diff keys on leaves" do
      d = Query.diff(fixture(), [scope: :sie], {:index, 1}, {:index, 3})
      assert d == %{rx_state: {1, 2}, tx_state: {0, 3}}
    end

    test "between time points uses most-recent-at-or-before" do
      d = Query.diff(fixture(), [scope: :sie], {:time, 0}, {:time, 250})
      # at ps<=250 the latest sample is index 2 (ps 200): rx_state 2, tx_state 0
      assert d == %{rx_state: {0, 2}}
    end

    test ":first / :last sentinels" do
      d = Query.diff(fixture(), [], :first, :last)
      # first (all 0) vs last (all 0) → no change
      assert d == %{}
    end
  end

  describe "snapshot/3" do
    test "full state at a point" do
      s = Query.snapshot(fixture(), [scope: :sie], {:index, 3})
      assert s == %{rx_state: 2, tx_state: 3}
    end

    test "defaults to :last" do
      s = Query.snapshot(fixture(), [])
      assert s[{[:top], :led}] == 0
    end
  end
end
