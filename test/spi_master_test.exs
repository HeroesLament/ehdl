defmodule Hw.SPIMasterTest.Lead do
  use Hw.Component

  clock :clk, freq: 48.0
  input  :rst,      1
  input  :tx_data,  8
  input  :tx_valid, 1
  input  :cs_hold,  1
  input  :miso,     1
  output :tx_ready, 1
  output :rx_data,  8
  output :rx_valid, 1
  output :sck,      1
  output :mosi,     1
  output :cs_n,     1

  instance :m, Hw.SPI.Master,
    MISO_SAMPLE_TRAILING: 1,
    MOSI_LAUNCH_LEADING: 1,
    CLK_FREQ: 8,
    SCK_FREQ: 1,
    clk: :clk, rst: :rst, tx_data: :tx_data, tx_valid: :tx_valid, cs_hold: :cs_hold,
    tx_ready: :tx_ready, rx_data: :rx_data, rx_valid: :rx_valid,
    sck: :sck, mosi: :mosi, miso: :miso, cs_n: :cs_n
end

defmodule Hw.SPIMasterTest.Mode0 do
  use Hw.Component

  clock :clk, freq: 48.0
  input  :rst,      1
  input  :tx_data,  8
  input  :tx_valid, 1
  input  :cs_hold,  1
  input  :miso,     1
  output :tx_ready, 1
  output :rx_data,  8
  output :rx_valid, 1
  output :sck,      1
  output :mosi,     1
  output :cs_n,     1

  instance :m, Hw.SPI.Master,
    CLK_FREQ: 8,
    SCK_FREQ: 1,
    clk: :clk, rst: :rst, tx_data: :tx_data, tx_valid: :tx_valid, cs_hold: :cs_hold,
    tx_ready: :tx_ready, rx_data: :rx_data, rx_valid: :rx_valid,
    sck: :sck, mosi: :mosi, miso: :miso, cs_n: :cs_n
end

defmodule Hw.SPIMasterTest do
  use ExUnit.Case
  import Bitwise

  alias Hw.Sim

  # Clocks one transfer per {tx, cs_hold} through the master with a slave model on
  # the pins. The slave samples MOSI on `sample` (:rise or :fall) and drives MISO
  # on `drive` (:rise: after each rising edge, :fall: after each falling edge)
  # from `resp`. Returns the per-cycle pin trace and what each side received.
  defp run(mod, bytes, resp, sample, drive) do
    {:ok, sim} = Sim.start(mod)
    for {p, v} <- [rst: 1, tx_data: 0, tx_valid: 0, cs_hold: 0, miso: 0], do: Sim.set(sim, p, v)
    Sim.tick(sim, :clk, 2)
    Sim.set(sim, :rst, 0)
    Sim.tick(sim, :clk, 2)

    pins = fn -> {Sim.get(sim, :sck), Sim.get(sim, :mosi), Sim.get(sim, :cs_n)} end
    resp_bits = for r <- resp, i <- 7..0//-1, do: r >>> i &&& 1
    # A rising-edge slave puts bit 0 out on the first rising edge, so it has
    # nothing valid before it; a falling-edge slave has bit 0 up from CS.
    resp_bits = if drive == :rise, do: [0 | resp_bits], else: resp_bits

    {trace, rx, _} =
      Enum.reduce(Enum.zip(bytes, resp), {[pins.()], [], resp_bits}, fn {{tx, hold}, _}, {trace, rx, rbits} ->
        for {p, v} <- [tx_data: tx, cs_hold: hold, tx_valid: 1], do: Sim.set(sim, p, v)
        trace = wait(sim, pins, trace, fn -> Sim.get(sim, :tx_ready) == 1 end)
        Sim.tick(sim, :clk, 1)
        Sim.set(sim, :tx_valid, 0)
        trace = [pins.() | trace]
        loop(sim, pins, trace, rx, rbits, drive)
      end)

    trace = Enum.reverse(trace)
    edges = Enum.zip(trace, tl(trace))
    got = for {{s0, m0, c0}, {s1, _, _}} <- edges, c0 == 0, edge?(s0, s1, sample), do: m0
    %{trace: trace, edges: edges, slave_rx: chunk(got), master_rx: Enum.reverse(rx)}
  end

  defp edge?(0, 1, :rise), do: true
  defp edge?(1, 0, :fall), do: true
  defp edge?(_, _, _), do: false

  defp wait(sim, pins, trace, done) do
    if done.(), do: trace, else: (Sim.tick(sim, :clk, 1); wait(sim, pins, [pins.() | trace], done))
  end

  # Run until the byte completes and the master is back in :idle.
  defp loop(sim, pins, trace, rx, rbits, drive) do
    {sck0, _, _} = hd(trace)
    Sim.tick(sim, :clk, 1)
    {sck1, _, _} = p = pins.()
    rbits = if edge?(sck0, sck1, drive) and rbits != [], do: tl(rbits), else: rbits
    # The slave puts its next bit on MISO at its drive edge; before the first one
    # the line already shows bit 0.
    Sim.set(sim, :miso, List.first(rbits) || 0)
    rx = if Sim.get(sim, :rx_valid) == 1, do: [Sim.get(sim, :rx_data) | rx], else: rx

    if Sim.get(sim, :tx_ready) == 1 and length(rx) > 0,
      do: {[p | trace], rx, rbits},
      else: loop(sim, pins, [p | trace], rx, rbits, drive)
  end

  defp chunk(bits), do: bits |> Enum.chunk_every(8) |> Enum.map(fn b -> Enum.reduce(b, 0, &(&2 <<< 1 ||| &1)) end)

  test "MOSI_LAUNCH_LEADING: MOSI and CS never move on an SCK falling edge" do
    bytes = [{0x80, 1}, {0x37, 1}, {0xA5, 0}]
    resp = [0x00, 0x00, 0x0A]
    r = run(Hw.SPIMasterTest.Lead, bytes, resp, :fall, :rise)

    # A falling-edge slave reads exactly what was sent.
    assert r.slave_rx == Enum.map(bytes, &elem(&1, 0))
    # And the master reads the rising-edge slave's reply.
    assert List.last(r.master_rx) == 0x0A

    for {{s0, m0, c0}, {s1, m1, c1}} <- r.edges, s0 == 1 and s1 == 0 do
      assert m0 == m1, "MOSI changed on an SCK falling edge"
      assert c0 == c1, "CS changed on an SCK falling edge"
    end

    # CS stays low across the cs_hold bytes: one assertion, one release.
    cs = r.trace |> Enum.map(&elem(&1, 2)) |> Enum.dedup()
    assert cs == [1, 0, 1]
  end

  test "default mode keeps mode-0 timing: MOSI advances as SCK falls" do
    bytes = [{0x5A, 0}]
    r = run(Hw.SPIMasterTest.Mode0, bytes, [0xC3], :rise, :fall)

    assert r.slave_rx == [0x5A]
    assert r.master_rx == [0xC3]
    moves = for {{1, m0, _}, {0, m1, _}} <- r.edges, m0 != m1, do: :fall
    assert moves != [], "default path should still shift MOSI on the falling edge"
  end
end
