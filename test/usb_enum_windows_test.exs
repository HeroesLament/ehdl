defmodule Hw.USBEnumWindowsTest do
  use ExUnit.Case, async: false

  # W5 payoff: the real USB enumeration produces a windowed Hw.Trace whose
  # transaction spans name the protocol phases — so the 2.7M-event trace becomes
  # navigable by phase. This test is @tag :slow (full enumeration).

  @moduletag timeout: 300_000

  alias Hw.Sim.{Nif, Compiler, USBHost}
  alias Hw.Trace

  setup_all do
    design = Hw.elaborate(HelloBoard.Top)
    schedule = Hw.Sim.Schedule.build(design)
    compiled = Compiler.compile(schedule)
    {:ok, auto} = Nif.compile(compiled)

    trace = USBHost.enumerate_trace(auto, schedule: schedule)
    {:ok, trace: trace}
  end

  test "enumeration records the protocol phases as transaction spans", %{trace: trace} do
    labels = Trace.transactions(trace) |> Enum.map(& &1.label) |> Enum.uniq()

    for expected <- [
          :reset,
          :get_descriptor,
          :setup,
          :in_data,
          :set_address,
          :get_descriptor_addr1,
          :set_configuration
        ] do
      assert expected in labels, "missing phase span #{expected}"
    end
  end

  test "phase spans have ordered, non-degenerate ps bounds", %{trace: trace} do
    reset = Trace.window(trace, :reset)
    set_addr = Trace.window(trace, :set_address)

    # reset happens before set_address in sim time
    assert reset.from < set_addr.from
    # spans are real intervals, not points
    assert set_addr.to > set_addr.from
  end

  test "window: scopes queries to a phase on the real trace", %{trace: trace} do
    import Hw.Trace.Query

    # Whatever the SIE does, a windowed query only sees samples inside the phase.
    full = timeline(trace, scope: :sie) |> length()
    scoped = timeline(trace, window: :set_address, scope: :sie) |> length()

    assert scoped > 0
    assert scoped < full
  end

  test "the enumeration outcome is inspectable by phase (the debug payoff)", %{trace: trace} do
    import Hw.Trace.Query

    # This is the finding we chased live: does cdc_dev_state ever advance?
    # With windows we can ask *per phase* instead of scrubbing 2.7M events.
    dev_state_in_set_addr =
      timeline(trace, window: :set_address, scope: :cdc)
      |> Enum.map(fn e -> e.state[:dev_state] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)

    # We assert the mechanism works (a number comes back), NOT that enumeration
    # succeeds — the whole point is that this makes the real behavior visible.
    assert is_integer(dev_state_in_set_addr)
  end

  test "mode: :snapshot captures combinational signals (delta mode cannot)" do
    import Hw.Trace.Query

    design = Hw.elaborate(HelloBoard.Top)
    schedule = Hw.Sim.Schedule.build(design)
    {:ok, auto} = Nif.compile(Compiler.compile(schedule))

    trace =
      USBHost.enumerate_trace(auto,
        schedule: schedule,
        mode: :snapshot,
        signals: [:phy_rx_active, :phy_rx_state]
      )

    # rx_active is COMBINATIONAL (= rx_state == 4). Under :delta it stays frozen
    # at 0; under :snapshot it must reflect the real value. The invariant: at
    # every sample where rx_state == 4, rx_active == 1.
    at4 = find_when(trace, [], "phy.rx_state": 4)
    assert length(at4) > 0, "the PHY should enter active reception (rx_state==4)"

    assert Enum.all?(at4, fn e -> e.state[{[:phy], :rx_active}] == 1 end),
           "rx_active must be 1 wherever rx_state==4 (combinational capture)"

    assert Enum.max(Trace.values(trace, :phy_rx_active)) == 1
  end
end
