defmodule Hw.TraceNifCharacterizationTest do
  use ExUnit.Case, async: true

  # M2 GATE: prove Hw.Trace.Adapter.Nif reproduces exactly what Hw.Waveform
  # records from the same NIF-backend run. We drive one design through the same
  # backend steps, building a %Waveform{} and a %Hw.Trace{} in lockstep, and
  # assert identical values at every cycle for every tracked signal — for both
  # the sparse (step_wave) and dense-snapshot (step_wave_each) paths.

  import Hw.Waveform.ExUnit, only: [build_schedule: 1]

  alias Hw.Sim.Backend
  alias Hw.Trace
  alias Hw.Trace.Adapter.Nif, as: TraceNif

  # Local copy of the fast UART TX used by fsm_waveform_test.exs (the original is
  # nested in another test module and not importable).
  defmodule FastTX do
    use Hw.Component

    param :CLK_FREQ, default: 48_000_000
    param :BAUD_RATE, default: 6_000_000

    clock :clk, freq: 48.0
    input :rst, 1
    input :data, 8
    input :valid, 1
    output :ready, 1
    output :txd, 1

    wire :baud_cnt, 20, init: 0
    wire :bit_cnt, 4, init: 0
    wire :shift_reg, 10, init: 0b1111111111
    wire :start_bit, 1
    wire :stop_bit, 1
    wire :tick, 1

    comb do
      start_bit = 0
      stop_bit = 1
      tick = baud_cnt == CLK_FREQ / BAUD_RATE - 1
      txd = shift_reg[0..0]
    end

    fsm :tx_state, clock: :clk, init: :idle do
      defaults do
        ready = 1
      end

      case tx_state do
        :idle ->
          ready = 1

          on valid do
            shift_reg = {stop_bit, data, start_bit}
            bit_cnt = 0
            baud_cnt = 0
            next(:sending)
          end

        :sending ->
          ready = 0
          baud_cnt = baud_cnt + 1

          on tick do
            baud_cnt = 0
            shift_reg = {stop_bit, shift_reg[9..1]}
            bit_cnt = bit_cnt + 1
            on(bit_cnt == 9, next: :idle)
          end
      end
    end
  end

  @signals [:txd, :ready, :tx_state, :valid]

  # Assert %Waveform{} and %Hw.Trace{} agree on every signal at every cycle.
  defp assert_agree(waves, %Trace{} = trace) do
    n = Hw.Waveform.cycle_count(waves)
    assert Trace.count(trace) == n, "sample counts differ: waveform=#{n}, trace=#{Trace.count(trace)}"

    for sig <- @signals, cycle <- 0..(n - 1) do
      wv = Hw.Waveform.at(waves, sig, cycle)
      tv = Trace.at(trace, sig, cycle)

      assert wv == tv,
             "mismatch at #{sig}[#{cycle}]: waveform=#{inspect(wv)} trace=#{inspect(tv)}"
    end
  end

  defp setup_sim do
    schedule = build_schedule(FastTX)
    {:ok, sim} = Backend.init(Backend.Nif, schedule)
    {sim, schedule}
  end

  defp reset(sim) do
    {:ok, sim, _} = Backend.step(Backend.poke!(sim, :rst, 1), :clk, 1)
    Backend.poke!(sim, :rst, 0)
  end

  test "step_wave_each (dense snapshot path) matches Hw.Waveform across a full frame" do
    # Two INDEPENDENT sims driven with identical stimulus. (Recorders must not
    # share a sim — step_wave* advances it, so sharing would double-step.)
    {simw, schedule} = setup_sim()
    {simt, schedule_t} = setup_sim()
    simw = reset(simw)
    simt = reset(simt)
    waves = Hw.Waveform.new(schedule, signals: @signals)
    trace = TraceNif.new(schedule_t, signals: @signals)

    # 2 idle cycles
    {simw, waves} = Backend.step_wave_each(simw, waves, :clk, 2)
    {simt, trace} = TraceNif.step_wave_each(simt, trace, :clk, 2)

    # assert valid, latch on rising edge
    simw = simw |> Backend.poke!(:data, 0xA5) |> Backend.poke!(:valid, 1)
    simt = simt |> Backend.poke!(:data, 0xA5) |> Backend.poke!(:valid, 1)
    {simw, waves} = Backend.step_wave_each(simw, waves, :clk, 1)
    {simt, trace} = TraceNif.step_wave_each(simt, trace, :clk, 1)
    simw = Backend.poke!(simw, :valid, 0)
    simt = Backend.poke!(simt, :valid, 0)

    # full 80-cycle frame
    {_simw, waves} = Backend.step_wave_each(simw, waves, :clk, 80)
    {_simt, trace} = TraceNif.step_wave_each(simt, trace, :clk, 80)

    assert_agree(waves, trace)

    # And a spot-check on the actual data: LSB-first 8N1 frame for 0xA5,
    # sampled at the midpoint of each 8-cycle bit period (same as fsm_waveform_test).
    frame_start = 3
    expected = [0, 1, 0, 1, 0, 0, 1, 0, 1, 1]

    for {bit, i} <- Enum.with_index(expected) do
      cycle = frame_start + i * 8 + 4
      assert Trace.at(trace, :txd, cycle) == bit, "txd bit #{i} at cycle #{cycle}"
    end
  end

  test "step_wave (sparse delta path) matches Hw.Waveform" do
    {simw, schedule} = setup_sim()
    {simt, schedule_t} = setup_sim()
    simw = reset(simw)
    simt = reset(simt)
    waves = Hw.Waveform.new(schedule, signals: @signals)
    trace = TraceNif.new(schedule_t, signals: @signals)

    # Batch-step: one sample per batch, fed from the sparse change log.
    {simw, waves} = Backend.step_wave(simw, waves, :clk, 1)
    {simt, trace} = TraceNif.step_wave(simt, trace, :clk, 1)

    simw = simw |> Backend.poke!(:data, 0x3C) |> Backend.poke!(:valid, 1)
    simt = simt |> Backend.poke!(:data, 0x3C) |> Backend.poke!(:valid, 1)
    {simw, waves} = Backend.step_wave(simw, waves, :clk, 1)
    {simt, trace} = TraceNif.step_wave(simt, trace, :clk, 1)
    simw = Backend.poke!(simw, :valid, 0)
    simt = Backend.poke!(simt, :valid, 0)

    {_simw, waves} = Backend.step_wave(simw, waves, :clk, 10)
    {_simt, trace} = TraceNif.step_wave(simt, trace, :clk, 10)

    assert_agree(waves, trace)
  end

  test "adapter resolves hierarchical scope for entity + top signals" do
    {_sim, schedule} = setup_sim()
    trace = TraceNif.new(schedule, signals: @signals)

    # FastTX is a flat component: all signals live in :top scope.
    assert Trace.address(trace, :txd) == {[:top], :txd}
    assert Trace.address(trace, :tx_state) == {[:top], :tx_state}
    assert Trace.scope_tree(trace) |> Map.keys() == [:top]
  end
end
