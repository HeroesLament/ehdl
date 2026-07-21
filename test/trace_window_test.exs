defmodule Hw.TraceWindowTest do
  use ExUnit.Case, async: true

  alias Hw.Trace
  alias Hw.Trace.Window

  defp empty do
    Trace.new([{:led, %{width: 1}}])
  end

  describe "begin_tr / end_tr" do
    test "opens and closes a named span with ps bounds" do
      t =
        empty()
        |> Trace.begin_tr(:setup, 1000)
        |> Trace.end_tr(:setup, 5000)

      w = Trace.window(t, :setup)
      assert w.label == :setup
      assert w.from == 1000
      assert w.to == 5000
      assert w.axis == :time
      assert Window.closed?(w)
      assert Window.duration(w) == 4000
    end

    test "an open span (never ended) has to: nil" do
      t = empty() |> Trace.begin_tr(:reset, 0)
      w = Trace.window(t, :reset)
      refute Window.closed?(w)
      assert Window.duration(w) == nil
    end
  end

  describe "nesting (advisory parent) + overlap" do
    test "inner span records the outer as parent" do
      t =
        empty()
        |> Trace.begin_tr(:set_address, 1000)
        |> Trace.begin_tr(:token, 1000)
        |> Trace.end_tr(:token, 1500)
        |> Trace.end_tr(:set_address, 3000)

      outer = Trace.window(t, :set_address)
      inner = Trace.window(t, :token)

      assert inner.parent == outer.id
      assert outer.parent == nil
    end

    test "overlapping (interleaved) spans are allowed — no stack discipline" do
      # A opens, B opens, A closes before B — illegal under strict nesting,
      # fine here.
      t =
        empty()
        |> Trace.begin_tr(:a, 0)
        |> Trace.begin_tr(:b, 100)
        |> Trace.end_tr(:a, 200)
        |> Trace.end_tr(:b, 300)

      a = Trace.window(t, :a)
      b = Trace.window(t, :b)
      assert {a.from, a.to} == {0, 200}
      assert {b.from, b.to} == {100, 300}
      # b's advisory parent was a (innermost open at b's begin)
      assert b.parent == a.id
    end

    test "end_tr closes the newest still-open span of that label" do
      t =
        empty()
        |> Trace.begin_tr(:token, 100)
        |> Trace.begin_tr(:token, 200)
        |> Trace.end_tr(:token, 250)

      [first, second] = Trace.windows(t, :token)
      # the second (newest) token closed at 250; the first stays open
      assert second.to == 250
      assert first.to == nil
    end

    test "end_tr with no matching open span is a no-op" do
      t = empty() |> Trace.end_tr(:nope, 500)
      assert Trace.transactions(t) == []
    end
  end

  describe "mark (point markers)" do
    test "zero-width span, from == to" do
      t = empty() |> Trace.mark(:reset_deasserted, 4200)
      w = Trace.window(t, :reset_deasserted)
      assert Window.point?(w)
      assert {w.from, w.to} == {4200, 4200}
    end
  end

  describe "lookup" do
    test "windows/2 returns all spans of a label in begin order" do
      t =
        empty()
        |> Trace.begin_tr(:token, 0)
        |> Trace.end_tr(:token, 10)
        |> Trace.begin_tr(:token, 100)
        |> Trace.end_tr(:token, 110)

      assert [%{from: 0}, %{from: 100}] = Trace.windows(t, :token)
    end

    test "window/2 raises on an ambiguous label" do
      t =
        empty()
        |> Trace.begin_tr(:token, 0)
        |> Trace.begin_tr(:token, 100)

      assert_raise ArgumentError, ~r/ambiguous/, fn -> Trace.window(t, :token) end
    end

    test "window/2 returns nil for an unknown label" do
      assert Trace.window(empty(), :missing) == nil
    end
  end

  describe "Window.bounds/2" do
    test "open span resolves end to default_to" do
      w = %Window{id: make_ref(), label: :x, from: 100, to: nil, axis: :time}
      assert Window.bounds(w, 999) == {100, 999}
    end

    test "closed span ignores default_to" do
      w = %Window{id: make_ref(), label: :x, from: 100, to: 500, axis: :time}
      assert Window.bounds(w, 999) == {100, 500}
    end
  end
end
