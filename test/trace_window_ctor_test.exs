defmodule Hw.TraceWindowCtorTest do
  use ExUnit.Case, async: true

  alias Hw.Trace
  alias Hw.Trace.Window
  alias Hw.Trace.Query

  # 8 samples at ps 0..700; sie_rx_state is >0 for two separate bursts:
  #   idx 2,3 (ps 200,300) and idx 5,6 (ps 500,600).
  defp trace do
    specs = [{:sie_rx_state, %{width: 3, init: 0}}]

    Enum.reduce(0..7, Trace.new(specs), fn i, t ->
      rx = cond do
        i in 2..3 -> 2
        i in 5..6 -> 1
        true -> 0
      end

      Trace.apply_snapshot(t, %{sie_rx_state: rx}, i * 100)
    end)
  end

  describe "Window.between (Tier 1)" do
    test "builds a span from two query events, ordered low..high" do
      a = %{time_ps: 100, index: 1}
      b = %{time_ps: 500, index: 5}
      w = Window.between(a, b, :region)
      assert {w.from, w.to} == {100, 500}
      assert w.label == :region
      assert w.axis == :time
    end

    test "orders bounds regardless of argument order" do
      w = Window.between(%{time_ps: 500}, %{time_ps: 100}, :r)
      assert {w.from, w.to} == {100, 500}
    end

    test "accepts bare ps integers" do
      w = Window.between(300, 600, :r)
      assert {w.from, w.to} == {300, 600}
    end

    test "composes with real find_when results" do
      [a | _] = Query.find_when(trace(), [scope: :sie], rx_state: 2)
      [b | _] = Query.find_when(trace(), [scope: :sie], rx_state: 1)
      w = Window.between(a, b, :rx_to_rx)
      # first rx_state==2 at ps 200, first rx_state==1 at ps 500
      assert {w.from, w.to} == {200, 500}
    end
  end

  describe "Window.around (Tier 1)" do
    test "centers on a point with symmetric padding" do
      w = Window.around(%{time_ps: 1000}, :glitch, pad: 250)
      assert {w.from, w.to} == {750, 1250}
    end

    test "clamps lower bound at 0" do
      w = Window.around(%{time_ps: 100}, :edge, pad: 500)
      assert {w.from, w.to} == {0, 600}
    end

    test "pad defaults to 0 (a point marker)" do
      w = Window.around(400, :pt)
      assert {w.from, w.to} == {400, 400}
      assert Window.point?(w)
    end
  end

  describe "Query.where (Tier 2 predicate extraction)" do
    test "extracts every maximal interval where the predicate holds" do
      wins = Query.where(trace(), [scope: :sie], :active, fn s -> s[:rx_state] > 0 end)
      assert length(wins) == 2
      assert Enum.map(wins, &{&1.from, &1.to}) == [{200, 300}, {500, 600}]
      assert Enum.all?(wins, &(&1.label == :active))
    end

    test "a single continuous run yields one window" do
      wins = Query.where(trace(), [scope: :sie], :any, fn s -> s[:rx_state] >= 0 end)
      # always true → one window spanning the whole trace
      assert length(wins) == 1
      assert {hd(wins).from, hd(wins).to} == {0, 700}
    end

    test "no matches yields an empty list" do
      wins = Query.where(trace(), [scope: :sie], :none, fn s -> s[:rx_state] == 99 end)
      assert wins == []
    end

    test "a run reaching the end of the trace is closed at the last sample" do
      # rx_state==1 at idx 5,6 then 0 at 7 — but make a trace ending mid-burst:
      specs = [{:sie_rx_state, %{width: 3, init: 0}}]

      t =
        Enum.reduce(0..3, Trace.new(specs), fn i, acc ->
          rx = if i >= 2, do: 1, else: 0
          Trace.apply_snapshot(acc, %{sie_rx_state: rx}, i * 100)
        end)

      [w] = Query.where(t, [scope: :sie], :tail, fn s -> s[:rx_state] > 0 end)
      # burst starts at idx 2 (ps 200) and runs to the end (idx 3, ps 300)
      assert {w.from, w.to} == {200, 300}
    end

    test "extracted windows compose with window: queries" do
      [w1, _w2] = Query.where(trace(), [scope: :sie], :active, fn s -> s[:rx_state] > 0 end)
      # feed the extracted window straight back into a scoped query
      tl = Query.timeline(trace(), window: w1, scope: :sie)
      assert Enum.map(tl, & &1.time_ps) == [200, 300]
    end
  end
end
