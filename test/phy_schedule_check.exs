defmodule PHYScheduleCheck do
  use ExUnit.Case

  test "inspect sample_cnt reg and phy entity clock", %{} do
    {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
    phy_entity = sim.schedule.entities[:phy]

    reg = Enum.find(phy_entity.ops, fn
      %Hw.IR.Ops.Reg{output: %{name: :phy_sample_cnt}} -> true
      _ -> false
    end)

    IO.puts("\nsample_cnt Reg:")
    IO.puts("  input name: #{reg.input.name}")
    IO.puts("  clock name: #{reg.clock.name}")
    IO.puts("  reset_value: #{inspect(reg.reset_value)}")

    IO.puts("\nphy entity domain: #{phy_entity.domain}")

    # Tick one clock and check if sample_cnt changes
    before = Hw.Sim.get(sim, :phy_sample_cnt)
    Hw.Sim.tick(sim, :clk_48, 1)
    after1 = Hw.Sim.get(sim, :phy_sample_cnt)
    Hw.Sim.tick(sim, :clk_48, 1)
    after2 = Hw.Sim.get(sim, :phy_sample_cnt)
    Hw.Sim.tick(sim, :clk_48, 1)
    after3 = Hw.Sim.get(sim, :phy_sample_cnt)
    Hw.Sim.tick(sim, :clk_48, 1)
    after4 = Hw.Sim.get(sim, :phy_sample_cnt)
    IO.puts("\nsample_cnt: #{before} → #{after1} → #{after2} → #{after3} → #{after4}")
  end
end
