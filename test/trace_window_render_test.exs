defmodule Hw.TraceWindowRenderTest do
  use ExUnit.Case, async: true

  import Hw.Trace.ExUnit

  alias Hw.Trace
  alias Hw.Trace.Render

  # 8 samples ps 0..700; sig == index. Two phases:
  #   :early over ps 100..300 (idx 1,2,3), :late over ps 500..600 (idx 5,6).
  # done goes 0..0..1 reaching 1 only at idx 6 (inside :late).
  defp trace do
    specs = [{:sig, %{width: 4, init: 0}}, {:done, %{width: 1, init: 0}}]

    base =
      Enum.reduce(0..7, Trace.new(specs), fn i, t ->
        done = if i >= 6, do: 1, else: 0
        Trace.apply_snapshot(t, %{sig: i, done: done}, i * 100)
      end)

    base
    |> Trace.begin_tr(:early, 100)
    |> Trace.end_tr(:early, 300)
    |> Trace.begin_tr(:late, 500)
    |> Trace.end_tr(:late, 600)
  end

  describe "Render.ascii window:" do
    test "renders a labeled phase band naming the window" do
      out = Render.ascii(trace(), window: :early, width: 50)
      assert out =~ "early"
      assert out =~ "╔"
    end

    test "windowed render narrows to fewer distinct sample values than full" do
      # Inspect the signal ROW specifically (the ruler line also contains digits).
      sig_row = fn out ->
        out |> String.split("\n") |> Enum.find(&String.contains?(&1, "sig"))
      end

      full = Render.ascii(trace(), signals: [:sig], width: 60) |> sig_row.()
      win = Render.ascii(trace(), signals: [:sig], window: :late, width: 60) |> sig_row.()

      # :late spans idx 5,6 → sig row shows 5 and 6 only; full row shows 7 too.
      assert full =~ "7"
      refute win =~ "7"
      assert win =~ "5"
      assert win =~ "6"
    end

    test "unknown window label raises" do
      assert_raise ArgumentError, ~r/unknown window/, fn ->
        Render.ascii(trace(), window: :nope)
      end
    end
  end

  describe "assert_stable window:" do
    test "asserts stability within a window's cycle range" do
      # done is 0 throughout :early (idx 1,2,3)
      assert_stable(trace(), :done, window: :early, value: 0)
    end

    test "fails when the signal isn't stable in the window" do
      # sig changes every cycle, so it is NOT stable across :early
      assert_raise RuntimeError, ~r/not stable/, fn ->
        assert_stable(trace(), :sig, window: :early)
      end
    end
  end

  describe "assert_reaches window:" do
    test "passes when the target is reached inside the window" do
      # done reaches 1 at idx 6, which is inside :late (idx 5,6)
      assert_reaches(trace(), :done, 1, window: :late)
    end

    test "fails when the target is never reached inside the window" do
      # done is never 1 during :early
      assert_raise RuntimeError, ~r/never reached/, fn ->
        assert_reaches(trace(), :done, 1, window: :early)
      end
    end

    test "window: takes precedence over by:" do
      # even with a generous by:, window: :early scopes the search and fails
      assert_raise RuntimeError, ~r/never reached/, fn ->
        assert_reaches(trace(), :done, 1, window: :early, by: 99)
      end
    end
  end
end
