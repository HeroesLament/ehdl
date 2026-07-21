defmodule Hw.UART.TX.WaveformTest do
  use ExUnit.Case, async: true

  import Hw.Waveform.ExUnit

  # ---------------------------------------------------------------------------
  # UART TX — FSM waveform tests
  #
  # Uses a fast test baud rate so each bit period is exactly 8 clock cycles
  # and a full 10-bit 8N1 frame is 80 cycles. This keeps waveforms tractable.
  #
  # All tests use step_wave_each/4 so every clock edge is its own waveform
  # sample. cycle N = state observed after the Nth rising edge of :clk.
  #
  # 0xA5 = 0b10100101, LSB-first 8N1 frame:
  #   start(0) d0(1) d1(0) d2(1) d3(0) d4(0) d5(1) d6(0) d7(1) stop(1)
  # ---------------------------------------------------------------------------

  # Minimal UART TX wired for fast simulation:
  # 48 MHz clock, 6 MHz baud → 8 clocks/bit, 80 clocks/frame.
  defmodule FastTX do
    use Hw.Component

    param :CLK_FREQ,  default: 48_000_000
    param :BAUD_RATE, default: 6_000_000

    clock :clk, freq: 48.0
    input  :rst,   1
    input  :data,  8
    input  :valid, 1
    output :ready, 1
    output :txd,   1

    wire :baud_cnt,  20, init: 0
    wire :bit_cnt,    4, init: 0
    wire :shift_reg, 10, init: 0b1111111111
    wire :start_bit,  1
    wire :stop_bit,   1
    wire :tick,       1

    comb do
      start_bit = 0
      stop_bit  = 1
      tick      = (baud_cnt == CLK_FREQ / BAUD_RATE - 1)
      txd       = shift_reg[0..0]
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
            bit_cnt   = 0
            baud_cnt  = 0
            next :sending
          end

        :sending ->
          ready    = 0
          baud_cnt = baud_cnt + 1
          on tick do
            baud_cnt  = 0
            shift_reg = {stop_bit, shift_reg[9..1]}
            bit_cnt   = bit_cnt + 1
            on bit_cnt == 9, next: :idle
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp setup_sim do
    schedule = build_schedule(FastTX)
    {:ok, sim} = Hw.Sim.Backend.init(Hw.Sim.Backend.Nif, schedule)
    {sim, schedule}
  end

  # One reset tick, then release.
  defp reset(sim) do
    {:ok, sim, _} = Hw.Sim.Backend.step(
      Hw.Sim.Backend.poke!(sim, :rst, 1), :clk, 1)
    Hw.Sim.Backend.poke!(sim, :rst, 0)
  end

  # Poke valid=1 with data, tick once (frame loads), drop valid.
  defp kick(sim, byte) do
    sim
    |> Hw.Sim.Backend.poke!(:data, byte)
    |> Hw.Sim.Backend.poke!(:valid, 1)
  end

  defp drop_valid(sim) do
    Hw.Sim.Backend.poke!(sim, :valid, 0)
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  test "idles high with ready=1 before any transmission" do
    {sim, schedule} = setup_sim()
    sim   = reset(sim)
    waves = Hw.Waveform.new(schedule, signals: [:txd, :ready, :tx_state])

    # 4 idle cycles with nothing driven
    {_sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 4)

    assert_stable waves, :txd,      value: 1, during: 0..3
    assert_stable waves, :ready,    value: 1, during: 0..3
    assert_stable waves, :tx_state, value: 0, during: 0..3
  end

  test "ready drops on the cycle valid is asserted, returns after frame" do
    {sim, schedule} = setup_sim()
    sim   = reset(sim)
    waves = Hw.Waveform.new(schedule, signals: [:valid, :ready, :tx_state])

    # 2 idle cycles
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 2)

    # Assert valid — tx latches on the rising edge
    sim = kick(sim, 0xA5)
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 1)
    sim = drop_valid(sim)

    # Run the full 80-cycle frame
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 80)

    # A few more idle cycles
    {_sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 3)

    # Before valid: ready=1, state=idle
    assert_stable waves, :ready,    value: 1, during: 0..1
    assert_stable waves, :tx_state, value: 0, during: 0..1

    # During frame: ready=0, state=sending
    # Frame is 80 cycles starting at cycle 3. The final cycle (82) is the
    # transition back to idle, so the stable window ends at 81.
    assert_stable waves, :ready,    value: 0, during: 3..81
    assert_stable waves, :tx_state, value: 1, during: 3..81

    # After frame: ready returns to 1
    assert_stable waves, :ready,    value: 1, during: 82..85
    assert_stable waves, :tx_state, value: 0, during: 82..85
  end

  test "txd output matches 8N1 frame for 0xA5" do
    # 0xA5 = 0b10100101
    # LSB-first frame: start(0) d0(1) d1(0) d2(1) d3(0) d4(0) d5(1) d6(0) d7(1) stop(1)
    # Frame begins on the cycle after valid is asserted (cycle 2 below).
    # Each bit holds for 8 cycles. Midpoint of bit N = frame_start + N*8 + 4.
    {sim, schedule} = setup_sim()
    sim   = reset(sim)
    waves = Hw.Waveform.new(schedule, signals: [:txd])

    # cycle 0: idle
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 1)

    # cycle 1: assert valid — frame loads on this edge
    sim = kick(sim, 0xA5)
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 1)
    sim = drop_valid(sim)

    # cycles 2..81: frame shifting out
    {_sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 81)

    # Frame starts at cycle 2. Sample midpoint of each 8-cycle bit period.
    frame_start   = 2
    expected_bits = [0, 1, 0, 1, 0, 0, 1, 0, 1, 1]

    for {expected_bit, bit_index} <- Enum.with_index(expected_bits) do
      midpoint = frame_start + bit_index * 8 + 4
      actual   = Hw.Waveform.at(waves, :txd, midpoint)
      assert actual == expected_bit,
        "txd mismatch at bit #{bit_index} (#{[:start,:d0,:d1,:d2,:d3,:d4,:d5,:d6,:d7,:stop] |> Enum.at(bit_index)}) " <>
        "cycle #{midpoint}: expected #{expected_bit}, got #{inspect(actual)}"
    end
  end

  test "txd is stable within each bit period — no mid-bit glitches" do
    {sim, schedule} = setup_sim()
    sim   = reset(sim)
    waves = Hw.Waveform.new(schedule, signals: [:txd])

    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 1)
    sim = kick(sim, 0xA5)
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 1)
    sim = drop_valid(sim)
    {_sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 81)

    frame_start   = 2
    expected_bits = [0, 1, 0, 1, 0, 0, 1, 0, 1, 1]

    for {expected_bit, bit_index} <- Enum.with_index(expected_bits) do
      # Each bit is stable for 7 cycles. The 8th cycle is the rising edge
      # where the shift register updates, so txd already reflects the next bit.
      period_start = frame_start + bit_index * 8
      period_end   = period_start + 6
      assert_stable waves, :txd, value: expected_bit, during: period_start..period_end
    end
  end

  test "txd idles high between back-to-back frames" do
    {sim, schedule} = setup_sim()
    sim   = reset(sim)
    waves = Hw.Waveform.new(schedule, signals: [:txd, :ready])

    # First frame
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 1)
    sim = kick(sim, 0xAA)
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 1)
    sim = drop_valid(sim)
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 80)
    # cycles 0..81

    # Inter-frame gap (ready should be 1, txd should be 1)
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 4)
    # cycles 82..85

    # Second frame
    sim = kick(sim, 0x55)
    {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 1)
    sim = drop_valid(sim)
    {_sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 80)

    # txd and ready both idle high during the gap
    assert_stable waves, :txd,   value: 1, during: 82..85
    assert_stable waves, :ready, value: 1, during: 82..85
  end
end
