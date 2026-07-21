defmodule HelloBoard.ResetTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
    Hw.Sim.set(sim, :pll_locked, 1)
    # rst_sync counter needs 1024 cycles to deassert rst.
    # Force the rst_sync registers to their post-lock steady state so
    # tests don't need to burn 1024 ticks just to get past reset.
    Hw.Sim.force_reg(sim, :rst_sync, %{
      rst_sync_sync0:   1,
      rst_sync_sync1:   1,
      rst_sync_counter: 1023,
      rst_sync_ready:   1,
    })
    Hw.Sim.tick(sim, :clk_48, 3)
    {:ok, sim: sim}
  end

  test "rst is high before PLL locks" do
    {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
    assert Hw.Sim.get(sim, :rst) == 1
  end

  test "rst deasserts when PLL locks", %{sim: sim} do
    assert Hw.Sim.get(sim, :rst) == 0
  end

  test "rst reasserts when pll_locked goes low", %{sim: sim} do
    Hw.Sim.set(sim, :pll_locked, 0)
    # sync0 = 0 on tick 1, sync1 = 0 on tick 2 → ready = 0 → rst = 1
    Hw.Sim.tick(sim, :clk_48, 3)
    assert Hw.Sim.get(sim, :rst) == 1
  end

  test "led bit 7 reflects pll_locked", %{sim: sim} do
    # led = {pll_locked, dtr, rts, cdc_rx_valid, cdc_tx_valid, wifi_rxd, wifi_txd, rst}
    # pll_locked is MSB (bit 7)
    led = Hw.Sim.get(sim, :led)
    assert Bitwise.band(led, 0x80) == 0x80
  end
end
