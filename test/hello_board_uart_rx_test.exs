defmodule HelloBoard.UARTRXTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # HelloBoard UART RX — integration test
  #
  # Uses Hw.UART.RX.recv/1 as the synchronization point: it ticks the sim
  # until the RX FSM has latched a byte and asserted valid, replacing the
  # raw uart_send + manual poll pattern.
  #
  # Data flow:
  #   wifi_txd (bit-banged) → UART RX FSM → cdc_tx_data/valid → CDC EP1 IN
  # ---------------------------------------------------------------------------

  setup do
    {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
    Hw.Sim.set(sim, :pll_locked, 1)
    Hw.Sim.set(sim, :wifi_txd, 1)
    HelloBoard.SimSetup.release_reset(sim)
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

  # Helper: drive a byte onto wifi_txd and wait for RX FSM to latch it.
  defp rx_byte(sim, byte) do
    rx_task = Task.async(fn -> Hw.UART.RX.recv(sim) end)
    Hw.Sim.uart_send(sim, :wifi_txd, byte)
    Task.await(rx_task, :infinity)
  end

  # Helper: simulate host ACK via ep_in_done, clearing ep1_in_busy.
  defp host_ack(sim) do
    Hw.Sim.force_reg(sim, :sie, %{sie_ep_in_done: 1, sie_ep_in_ep: 1})
    Hw.Sim.tick(sim, :clk_48, 1)
    Hw.Sim.force_reg(sim, :sie, %{sie_ep_in_done: 0})
    Hw.Sim.tick(sim, :clk_48, 1)
  end

  test "byte on wifi_txd is loaded into EP1 IN buffer", %{sim: sim} do
    rx_byte(sim, 0x55)

    assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 1
    assert Hw.Sim.get(sim, :sie_ep_in_data)  == 0x55
    assert Hw.Sim.get(sim, :sie_ep_in_ep)    == 1
  end

  test "ep1_in_busy clears after host ACK", %{sim: sim} do
    rx_byte(sim, 0x42)
    assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 1

    host_ack(sim)

    assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 0
    assert Hw.Sim.get(sim, :cdc_tx_ready)    == 1
  end

  test "consecutive bytes each load the EP1 IN buffer", %{sim: sim} do
    rx_byte(sim, 0x41)
    assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 1
    assert Hw.Sim.get(sim, :sie_ep_in_data)  == 0x41

    host_ack(sim)

    rx_byte(sim, 0x42)
    assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 1
    assert Hw.Sim.get(sim, :sie_ep_in_data)  == 0x42
  end
end
