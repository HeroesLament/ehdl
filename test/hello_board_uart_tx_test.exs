defmodule HelloBoard.UARTTXTest do
  use ExUnit.Case, async: true
  @moduletag timeout: :infinity

  import Hw.Waveform.ExUnit

  # ---------------------------------------------------------------------------
  # HelloBoard UART TX — integration test
  #
  # Tests that bytes delivered by the USB CDC EP1 OUT path actually appear
  # on wifi_rxd as 8N1 UART frames. Drives stimulus through the proper
  # hardware dataflow: SIE ep_out → CDC → UART TX → wifi_rxd.
  #
  # Note: uart_tx_ready is wired to cdc_rx_ready (a shared bus signal) so
  # it has no prefixed entry in the schedule. Use uart_tx_tx_state instead:
  # 0 = idle, 1 = sending.
  # ---------------------------------------------------------------------------

  setup do
    {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
    Hw.Sim.set(sim, :pll_locked, 1)
    Hw.Sim.set(sim, :wifi_txd, 1)
    Hw.Sim.force_reg(sim, :rst_sync, %{
      rst_sync_sync0: 1, rst_sync_sync1: 1,
      rst_sync_counter: 1023, rst_sync_ready: 1,
    })
    Hw.Sim.force_reg(sim, :sie, %{
      sie_ep_out_valid: 0, sie_ep_out_pkt_end: 0,
      sie_ep_out_data: 0,  sie_ep_out_ep: 0,
      sie_ep_out_setup: 0,
    })
    Hw.Sim.force_reg(sim, :cdc, %{
      cdc_dev_state:   2,
      cdc_ep1_toggle:  0,
      cdc_ep1_in_busy: 0,
      cdc_out_valid:   0,
      cdc_out_byte:    0,
    })
    Hw.Sim.tick(sim, :clk_48, 2)
    {:ok, sim: sim}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tick_wave(sim, waves, n \\ 1)
  defp tick_wave(sim, waves, n) do
    signal_names = Map.keys(waves.signals)
    Enum.reduce(1..n, waves, fn _, w ->
      Hw.Sim.tick(sim, :clk_48, 1)
      # Use Hw.Sim.get for each signal to force lazy closure evaluation for
      # combinational outputs like wifi_rxd that aren't updated by cross-settle.
      snap = Map.new(signal_names, fn name ->
        {name, Hw.Sim.get(sim, name)}
      end)
      Hw.Waveform.record_snapshot(w, snap)
    end)
  end

  defp deliver_ep1_byte(sim, byte) do
    Hw.Sim.force_reg(sim, :sie, %{
      sie_ep_out_valid: 1,
      sie_ep_out_ep:    1,
      sie_ep_out_data:  byte,
      sie_ep_out_setup: 0,
      sie_ep_out_pkt_end: 0,
    })
    Hw.Sim.tick(sim, :clk_48, 1)
    Hw.Sim.force_reg(sim, :sie, %{sie_ep_out_valid: 0})
  end

  # ---------------------------------------------------------------------------
  # Original tests
  # ---------------------------------------------------------------------------

  test "byte delivered via EP1 OUT appears on wifi_rxd", %{sim: sim} do
    deliver_ep1_byte(sim, 0x55)
    assert {:ok, 0x55} = Hw.Sim.uart_recv(sim, :wifi_rxd, timeout: 120_000)
  end

  test "second byte delivered after first frame completes", %{sim: sim} do
    deliver_ep1_byte(sim, 0x41)
    {:ok, first} = Hw.Sim.uart_recv(sim, :wifi_rxd, timeout: 120_000)
    assert first == 0x41

    # Wait for UART TX FSM to return to idle
    Hw.Sim.wait_for(sim, :uart_tx_tx_state, 0, timeout: 120_000)

    deliver_ep1_byte(sim, 0x42)
    {:ok, second} = Hw.Sim.uart_recv(sim, :wifi_rxd, timeout: 120_000)
    assert second == 0x42
  end

  # ---------------------------------------------------------------------------
  # Waveform tests
  # ---------------------------------------------------------------------------

  test "wifi_rxd idles high between frames", %{sim: sim} do
    deliver_ep1_byte(sim, 0x55)
    Hw.Sim.uart_recv(sim, :wifi_rxd, timeout: 120_000)

    # Wait for TX FSM to return to idle
    Hw.Sim.wait_for(sim, :uart_tx_tx_state, 0, timeout: 120_000)

    waves = Hw.Waveform.new(sim.schedule,
      signals: [:wifi_rxd, :uart_tx_tx_state]
    )

    waves = tick_wave(sim, waves, 100)

    assert_stable waves, :wifi_rxd,          value: 1, during: 0..99
    assert_stable waves, :uart_tx_tx_state,  value: 0, during: 0..99
  end

  test "uart_tx_tx_state is 1 for the duration of a frame", %{sim: sim} do
    waves = Hw.Waveform.new(sim.schedule,
      signals: [:uart_tx_tx_state, :wifi_rxd]
    )

    # One idle tick before triggering
    waves = tick_wave(sim, waves, 1)

    # Deliver byte — TX goes to sending state
    deliver_ep1_byte(sim, 0xA5)
    waves = tick_wave(sim, waves, 1)

    # UART TX at 115200 baud / 48 MHz = 416 clocks/bit × 10 bits = 4160 clocks
    waves = tick_wave(sim, waves, 4200)

    # TX must have gone to sending state
    assert_reaches waves, :uart_tx_tx_state, 1, by: 3

    # TX must return to idle within the frame window
    assert_reaches waves, :uart_tx_tx_state, 0, by: 4170
  end
end
