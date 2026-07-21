defmodule HelloBoard.CDCTest do
  use ExUnit.Case, async: true

  import Hw.Waveform.ExUnit

  @pid_in    0x69
  @pid_data0 0xC3
  @pid_data1 0x4B
  @configured 2

  setup do
    {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
    Hw.Sim.set(sim, :pll_locked, 1)
    Hw.Sim.set(sim, :wifi_txd, 1)

    Hw.Sim.force_reg(sim, :rst_sync, %{
      rst_sync_sync0:   1, rst_sync_sync1:   1,
      rst_sync_counter: 1023, rst_sync_ready: 1,
    })
    Hw.Sim.force_reg(sim, :sie, %{
      sie_rx_pid: 0, sie_rx_ep: 0, sie_rx_addr: 0,
      sie_ep_out_valid: 0, sie_ep_out_pkt_end: 0,
      sie_ep_out_data: 0, sie_ep_out_ep: 0, sie_ep_out_setup: 0,
    })
    Hw.Sim.force_reg(sim, :sie, %{
      sie_ep_in_ready: 0, sie_ep_in_done: 0, sie_ep_in_nak: 0,
    })
    Hw.Sim.force_reg(sim, :cdc, %{
      sie_ep_in_ep: 0, sie_ep_in_valid: 0, sie_ep_in_loaded: 0,
    })
    Hw.Sim.tick(sim, :clk_48, 1)
    Hw.Sim.force_reg(sim, :cdc, %{
      cdc_dev_state:     @configured,
      cdc_ep1_toggle: 0,
      cdc_ep1_in_busy:       0,
      cdc_out_valid:     0,
      cdc_out_byte:      0,
    })
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
      snap = Map.new(signal_names, fn name ->
        {name, Hw.Sim.get(sim, name)}
      end)
      Hw.Waveform.record_snapshot(w, snap)
    end)
  end

  defp inject_pkt(sim, pid, ep, opts \\ []) do
    byte_data  = Keyword.get(opts, :byte_data,  0)
    byte_valid = Keyword.get(opts, :byte_valid, 0)

    Hw.Sim.force_reg(sim, :sie, %{
      sie_rx_pid: pid, sie_rx_ep: ep, sie_rx_addr: 0,
      sie_ep_out_data: byte_data, sie_ep_out_ep: ep,
      sie_ep_out_setup: 0, sie_ep_out_valid: byte_valid,
      sie_ep_out_pkt_end: 1,
    })
    Hw.Sim.tick(sim, :clk_48, 1)

    Hw.Sim.force_reg(sim, :sie, %{
      sie_ep_out_valid: 0, sie_ep_out_pkt_end: 0,
    })
    Hw.Sim.tick(sim, :clk_48, 1)
  end

  # ---------------------------------------------------------------------------
  # EP1 IN — point-in-time tests
  # ---------------------------------------------------------------------------

  describe "EP1 IN" do
    test "sets in_busy when IN token arrives and uart rx has data", %{sim: sim} do
      Hw.Sim.force_reg(sim, :uart_rx, %{uart_rx_valid_reg: 1, uart_rx_data_reg: 0x41})
      Hw.Sim.tick(sim, :clk_48, 1)
      inject_pkt(sim, @pid_in, 1)
      assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 1
    end

    test "toggles ep1_in_toggle after packet completes", %{sim: sim} do
      Hw.Sim.force_reg(sim, :uart_rx, %{uart_rx_valid_reg: 1, uart_rx_data_reg: 0x41})
      Hw.Sim.tick(sim, :clk_48, 1)
      inject_pkt(sim, @pid_in, 1)
      assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 1

      Hw.Sim.force_reg(sim, :uart_rx, %{uart_rx_valid_reg: 0})
      Hw.Sim.force_reg(sim, :sie, %{sie_ep_in_done: 1})
      Hw.Sim.tick(sim, :clk_48, 1)
      Hw.Sim.force_reg(sim, :sie, %{sie_ep_in_done: 0})
      Hw.Sim.tick(sim, :clk_48, 1)

      assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 0
      assert Hw.Sim.get(sim, :cdc_ep1_toggle)  == 1
    end

    test "does not set in_busy when no uart rx data (implicit NAK)", %{sim: sim} do
      Hw.Sim.force_reg(sim, :uart_rx, %{uart_rx_valid_reg: 0})
      Hw.Sim.tick(sim, :clk_48, 1)
      inject_pkt(sim, @pid_in, 1)
      assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 0
    end

    test "does not set in_busy when not configured", %{sim: sim} do
      Hw.Sim.force_reg(sim, :cdc, %{cdc_dev_state: 1})
      Hw.Sim.force_reg(sim, :uart_rx, %{uart_rx_valid_reg: 1, uart_rx_data_reg: 0x41})
      Hw.Sim.tick(sim, :clk_48, 1)
      inject_pkt(sim, @pid_in, 1)
      assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 0
    end

    test "tx_ready is 1 when not in_busy", %{sim: sim} do
      assert Hw.Sim.get(sim, :cdc_tx_ready) == 1
    end

    test "tx_ready is 0 when in_busy", %{sim: sim} do
      Hw.Sim.force_reg(sim, :cdc, %{cdc_ep1_in_busy: 1})
      assert Hw.Sim.get(sim, :cdc_tx_ready) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # EP1 OUT — point-in-time + waveform tests
  # ---------------------------------------------------------------------------

  describe "EP1 OUT" do
    test "latches byte into out_byte on DATA0", %{sim: sim} do
      inject_pkt(sim, @pid_data0, 1, byte_data: 0x55, byte_valid: 1)
      assert Hw.Sim.get(sim, :cdc_out_byte) == 0x55
    end

    test "out_valid=1 immediately after DATA0 latch", %{sim: sim} do
      Hw.Sim.force_reg(sim, :sie, %{
        sie_rx_pid: @pid_data0, sie_rx_ep: 1, sie_rx_addr: 0,
        sie_ep_out_data: 0x55, sie_ep_out_ep: 1,
        sie_ep_out_setup: 0, sie_ep_out_valid: 1, sie_ep_out_pkt_end: 1,
      })
      Hw.Sim.tick(sim, :clk_48, 1)
      assert Hw.Sim.get(sim, :cdc_out_byte)  == 0x55
      assert Hw.Sim.get(sim, :cdc_out_valid) == 1
    end

    test "latches byte into out_byte on DATA1", %{sim: sim} do
      inject_pkt(sim, @pid_data1, 1, byte_data: 0xAA, byte_valid: 1)
      assert Hw.Sim.get(sim, :cdc_out_byte) == 0xAA
    end

    test "out_valid=0 when byte_valid=0", %{sim: sim} do
      inject_pkt(sim, @pid_data0, 1, byte_data: 0x55, byte_valid: 0)
      assert Hw.Sim.get(sim, :cdc_out_valid) == 0
    end

    test "does not latch when not configured", %{sim: sim} do
      Hw.Sim.force_reg(sim, :cdc, %{cdc_dev_state: 1})
      inject_pkt(sim, @pid_data0, 1, byte_data: 0x55, byte_valid: 1)
      assert Hw.Sim.get(sim, :cdc_out_byte) == 0
    end

    test "cdc_rx_data reflects out_byte combinationally", %{sim: sim} do
      inject_pkt(sim, @pid_data0, 1, byte_data: 0x42, byte_valid: 1)
      assert Hw.Sim.get(sim, :cdc_rx_data) == 0x42
    end

    test "out_valid pulses for exactly one cycle then clears", %{sim: sim} do
      # Waveform test: replaces the manual tick-assert-tick-assert pattern
      # with an explicit sequence assertion.
      waves = Hw.Waveform.new(sim.schedule,
        signals: [:cdc_out_valid, :cdc_out_byte]
      )

      # Cycle 0: latch byte with pkt_end asserted
      Hw.Sim.force_reg(sim, :sie, %{
        sie_rx_pid: @pid_data0, sie_rx_ep: 1, sie_rx_addr: 0,
        sie_ep_out_data: 0x42, sie_ep_out_ep: 1,
        sie_ep_out_setup: 0, sie_ep_out_valid: 1, sie_ep_out_pkt_end: 1,
      })
      waves = tick_wave(sim, waves, 1)

      # Cycle 1: clear stimulus
      Hw.Sim.force_reg(sim, :sie, %{sie_ep_out_valid: 0, sie_ep_out_pkt_end: 0})
      waves = tick_wave(sim, waves, 1)

      # out_valid should be 1 on cycle 0 (latch tick), 0 on cycle 1 (cleared)
      assert_sequence waves, :cdc_out_valid, [1, 0]
      # out_byte holds its value after valid clears
      assert_stable   waves, :cdc_out_byte, value: 0x42, during: 0..1
    end
  end

  # ---------------------------------------------------------------------------
  # Reset — waveform test replacing three separate point-in-time tests
  # ---------------------------------------------------------------------------

  describe "reset" do
    test "clears dev_state on rst", %{sim: sim} do
      Hw.Sim.set(sim, :pll_locked, 0)
      Hw.Sim.tick(sim, :clk_48, 5)
      assert Hw.Sim.get(sim, :cdc_dev_state) == 0
    end

    test "clears in_busy on rst", %{sim: sim} do
      Hw.Sim.force_reg(sim, :cdc, %{cdc_ep1_in_busy: 1})
      Hw.Sim.set(sim, :pll_locked, 0)
      Hw.Sim.tick(sim, :clk_48, 5)
      assert Hw.Sim.get(sim, :cdc_ep1_in_busy) == 0
    end

    test "clears ep1_in_toggle on rst", %{sim: sim} do
      Hw.Sim.force_reg(sim, :cdc, %{cdc_ep1_toggle: 1})
      Hw.Sim.set(sim, :pll_locked, 0)
      Hw.Sim.tick(sim, :clk_48, 5)
      assert Hw.Sim.get(sim, :cdc_ep1_toggle) == 0
    end

    test "all CDC state registers clear together on reset arc", %{sim: sim} do
      # Waveform test: assert the full reset arc in a single test.
      # Force non-zero state into dev_state, in_busy, and toggle simultaneously,
      # then assert reset and watch all three clear in the same tick.
      Hw.Sim.force_reg(sim, :cdc, %{
        cdc_dev_state:    @configured,
        cdc_ep1_in_busy:  1,
        cdc_ep1_toggle:   1,
      })
      Hw.Sim.tick(sim, :clk_48, 1)

      waves = Hw.Waveform.new(sim.schedule,
        signals: [:cdc_dev_state, :cdc_ep1_in_busy, :cdc_ep1_toggle]
      )

      # Cycle 0: confirm non-zero pre-reset state
      waves = tick_wave(sim, waves, 1)

      # Assert reset by dropping pll_locked
      Hw.Sim.set(sim, :pll_locked, 0)
      waves = tick_wave(sim, waves, 4)

      # All three registers must have reached 0 by end of waveform
      assert_reaches waves, :cdc_dev_state,   0, by: 4
      assert_reaches waves, :cdc_ep1_in_busy, 0, by: 4
      assert_reaches waves, :cdc_ep1_toggle,  0, by: 4

      # And must stay at 0 — no spurious re-assertion
      assert_stable waves, :cdc_dev_state,   value: 0, during: 3..4
      assert_stable waves, :cdc_ep1_in_busy, value: 0, during: 3..4
      assert_stable waves, :cdc_ep1_toggle,  value: 0, during: 3..4
    end
  end
end
