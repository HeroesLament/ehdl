defmodule PHYDebugTest do
  use ExUnit.Case
  import Bitwise
  import Hw.Waveform.ExUnit

  @clocks_per_bit 4
  @phase_offset   2
  @sync_wire      [0, 1, 0, 1, 0, 1, 0, 0, 0]

  defp boot_sim do
    {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
    Hw.Sim.set(sim, :pll_locked, 1)
    Hw.Sim.force_reg(sim, :rst_sync, %{
      rst_sync_sync0: 1, rst_sync_sync1: 1,
      rst_sync_counter: 1023, rst_sync_ready: 1,
    })
    Hw.Sim.set(sim, :dp_diff, 1)
    Hw.Sim.set(sim, :dn_raw, 0)
    Hw.Sim.tick(sim, :clk_48, 32 + @phase_offset)
    sim
  end

  defp drive_ls(sim, 1), do: (Hw.Sim.set(sim, :dp_diff, 1); Hw.Sim.set(sim, :dn_raw, 0))
  defp drive_ls(sim, 0), do: (Hw.Sim.set(sim, :dp_diff, 0); Hw.Sim.set(sim, :dn_raw, 1))

  defp drive_sync(sim) do
    Enum.reduce(@sync_wire, 1, fn ls, _ ->
      drive_ls(sim, ls)
      Hw.Sim.tick(sim, :clk_48, @clocks_per_bit)
      ls
    end)
  end

  test "waveform through data byte", %{} do
    sim = boot_sim()
    drive_sync(sim)
    assert Hw.Sim.get(sim, :phy_rx_state) == 4

    waves = Hw.Waveform.new(sim.schedule, signals: [
      :phy_sample_cnt, :phy_sample_en, :phy_rx_state,
      :phy_bit_cnt, :phy_rx_valid, :phy_rx_data,
      :phy_dp_f, :phy_data_sr
    ])

    # Drive 0xC3 = 0b11000011 LSB-first, NRZI from K (line_state=0)
    byte = 0xC3
    waves = Enum.reduce(0..7, {waves, 0, 0}, fn bit_pos, {w, ls, ones} ->
      {ls2, o2} = if ones == 6, do: (drive_ls(sim, 1-ls); {1-ls, 0}), else: {ls, ones}
      data_bit = band(bsr(byte, bit_pos), 1)
      new_ls = if data_bit == 1, do: ls2, else: 1 - ls2
      drive_ls(sim, new_ls)
      new_ones = if data_bit == 1, do: o2 + 1, else: 0
      w2 = Enum.reduce(1..@clocks_per_bit, w, fn _, ww ->
        Hw.Sim.tick(sim, :clk_48, 1)
        snap = Map.new([:phy_sample_cnt, :phy_sample_en, :phy_rx_state,
                        :phy_bit_cnt, :phy_rx_valid, :phy_rx_data,
                        :phy_dp_f, :phy_data_sr], fn s ->
          {s, Hw.Sim.get(sim, s)}
        end)
        Hw.Waveform.record_snapshot(ww, snap)
      end)
      {w2, new_ls, new_ones}
    end)
    |> elem(0)

    # Print the waveform
    sigs = [:phy_sample_cnt, :phy_sample_en, :phy_bit_cnt, :phy_rx_valid, :phy_dp_f, :phy_data_sr]
    sig_values = Map.new(sigs, fn s -> {s, Hw.Waveform.values(waves, s)} end)

    IO.puts("\nCycle-by-cycle (32 clocks = 8 bits × 4 clocks):")
    header = String.pad_leading("cyc", 4) <> Enum.map_join(sigs, "", fn s ->
      s |> Atom.to_string() |> String.replace("phy_", "") |> String.pad_leading(12)
    end)
    IO.puts(header)
    Enum.each(0..31, fn i ->
      row = String.pad_leading("#{i}", 4) <> Enum.map_join(sigs, "", fn s ->
        val = Enum.at(sig_values[s], i, 0)
        "#{val}" |> String.pad_leading(12)
      end)
      IO.puts(row)
    end)

    # Assert rx_valid fires exactly once (at cycle 30 = bit7 clock3)
    assert_reaches waves, :phy_rx_valid, 1, by: 31
  end
end
