defmodule Hw.AD936xTxPortTest do
  use ExUnit.Case
  import Bitwise

  alias Hw.AD936xTxPort

  @samples %{i1: 0xABC, q1: 0x123, i2: 0x456, q2: 0x789}

  # Reference model: the edge sequence the AD936x expects in LVDS 2R2T,
  # I1msb Q1msb I1lsb Q1lsb | I2msb Q2msb I2lsb Q2lsb, as (rise, fall, frame)
  # per DATA_CLK cycle, with the three runtime swaps applied.
  defp expected(%{i1: i1, q1: q1, i2: i2, q2: q2}, opts) do
    {c1r, c1f, c2r, c2f} = if opts[:iq_swap], do: {q1, i1, q2, i2}, else: {i1, q1, i2, q2}
    {ra, fa, rb, fb} = if opts[:chan_swap], do: {c2r, c2f, c1r, c1f}, else: {c1r, c1f, c2r, c2f}
    hi = &(&1 >>> 6 &&& 0x3F)
    lo = &(&1 &&& 0x3F)
    {first, second} = if opts[:half_swap], do: {lo, hi}, else: {hi, lo}

    [
      {first.(ra), first.(fa), 1},
      {second.(ra), second.(fa), 1},
      {first.(rb), first.(fb), 0},
      {second.(rb), second.(fb), 0}
    ]
  end

  defp run(opts, cycles \\ 24) do
    {:ok, sim} = Hw.Sim.start(AD936xTxPort)
    Hw.Sim.set(sim, :enable, 0)
    for {k, v} <- @samples, do: Hw.Sim.set(sim, k, v)
    Hw.Sim.set(sim, :half_swap, if(opts[:half_swap], do: 1, else: 0))
    Hw.Sim.set(sim, :iq_swap, if(opts[:iq_swap], do: 1, else: 0))
    Hw.Sim.set(sim, :chan_swap, if(opts[:chan_swap], do: 1, else: 0))
    Hw.Sim.tick(sim, :clk, 2)
    Hw.Sim.set(sim, :enable, 1)

    for _ <- 1..cycles do
      Hw.Sim.tick(sim, :clk, 1)

      {Hw.Sim.get(sim, :d_rise), Hw.Sim.get(sim, :d_fall), Hw.Sim.get(sim, :frame_rise),
       Hw.Sim.get(sim, :frame_fall), Hw.Sim.get(sim, :sample_req)}
    end
  end

  # One frame starting at a frame 0->1 transition that carries real samples
  # (the first frame after enable carries the init-zero latch).
  defp a_frame(trace) do
    trace
    |> Enum.chunk_every(4, 1, :discard)
    |> Enum.find(fn [{r, f, 1, 1, _} | _] = w -> {r, f} != {0, 0} and length(w) == 4
                    _ -> false end)
    |> Enum.map(fn {r, f, fr, _ff, _req} -> {r, f, fr} end)
  end

  for opts <- [[], [half_swap: true], [iq_swap: true], [chan_swap: true],
               [half_swap: true, iq_swap: true, chan_swap: true]] do
    test "edge order #{inspect(opts)}" do
      trace = run(unquote(opts))
      assert a_frame(trace) == expected(@samples, unquote(opts))
    end
  end

  test "frame is high on both edges for exactly two of every four cycles" do
    frames = run([]) |> Enum.drop(8) |> Enum.map(fn {_, _, fr, ff, _} -> {fr, ff} end)
    assert Enum.all?(frames, fn {fr, ff} -> fr == ff end)
    assert frames |> Enum.chunk_every(4) |> Enum.all?(&(Enum.count(&1, fn {fr, _} -> fr == 1 end) == 2))
  end

  test "sample_req pulses once per frame" do
    reqs = run([]) |> Enum.drop(4) |> Enum.map(fn t -> elem(t, 4) end)
    assert reqs |> Enum.chunk_every(4) |> Enum.all?(&(Enum.sum(&1) == 1))
  end

  test "disabled: all outputs zero" do
    {:ok, sim} = Hw.Sim.start(AD936xTxPort)
    Hw.Sim.set(sim, :enable, 0)
    for {k, v} <- @samples, do: Hw.Sim.set(sim, k, v)
    for k <- [:half_swap, :iq_swap, :chan_swap], do: Hw.Sim.set(sim, k, 0)
    Hw.Sim.tick(sim, :clk, 8)
    assert {0, 0, 0, 0} ==
             {Hw.Sim.get(sim, :d_rise), Hw.Sim.get(sim, :d_fall),
              Hw.Sim.get(sim, :frame_rise), Hw.Sim.get(sim, :sample_req)}
  end
end
