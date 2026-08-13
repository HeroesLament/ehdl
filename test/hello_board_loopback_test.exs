defmodule HelloBoard.LoopbackTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Full RX→CDC loopback using the UART RX functional interface.
  #
  # Hw.UART.RX.recv/1 ticks the simulation until the RX FSM has latched a
  # byte and asserted valid, then returns. This exercises the same hardware
  # path as the bit-bang uart_send approach but through the component's own
  # sim protocol.
  #
  # Data flow:
  #   wifi_txd (bit-banged) → UART RX FSM → CDC EP1 IN buffer
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

  defp loopback(sim, byte) do
    rx_task = Task.async(fn -> Hw.UART.RX.recv(sim) end)
    Hw.Sim.uart_send(sim, :wifi_txd, byte)
    Task.await(rx_task, :infinity)

    assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 1
    assert Hw.Sim.get(sim, :sie_ep_in_data)  == byte
    assert Hw.Sim.get(sim, :sie_ep_in_ep)    == 1
  end

  test "0x00", %{sim: sim}, do: loopback(sim, 0x00)
  test "0xFF", %{sim: sim}, do: loopback(sim, 0xFF)
  test "0x55", %{sim: sim}, do: loopback(sim, 0x55)
  test "0xAA", %{sim: sim}, do: loopback(sim, 0xAA)
  test "'A'",  %{sim: sim}, do: loopback(sim, ?A)
  test "'Z'",  %{sim: sim}, do: loopback(sim, ?Z)
end
