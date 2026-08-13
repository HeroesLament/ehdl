defmodule RegFIFO8Test do
  use ExUnit.Case
  @moduletag timeout: :infinity

  alias Hw.RegFIFO8

  # Same invariants as RegFIFO16Test, at the depth the LibreSDR stream
  # revision actually ships (see Hw.RegFIFO8's moduledoc for why 8).

  defp start_dut do
    {:ok, sim} = Hw.Sim.start(RegFIFO8)
    Hw.Sim.set(sim, :rst, 1)
    Hw.Sim.set(sim, :wr_en, 0)
    Hw.Sim.set(sim, :rd_en, 0)
    Hw.Sim.set(sim, :wr_data, 0)
    Hw.Sim.tick(sim, :clk, 2)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.tick(sim, :clk, 1)
    sim
  end

  defp push(sim, v) do
    Hw.Sim.set(sim, :wr_en, 1)
    Hw.Sim.set(sim, :wr_data, v)
    Hw.Sim.tick(sim, :clk, 1)
    Hw.Sim.set(sim, :wr_en, 0)
  end

  defp pop(sim) do
    v = Hw.Sim.get(sim, :rd_data)
    Hw.Sim.set(sim, :rd_en, 1)
    Hw.Sim.tick(sim, :clk, 1)
    Hw.Sim.set(sim, :rd_en, 0)
    v
  end

  describe "structure" do
    setup do
      {:ok, design: Hw.Compile.Elaborate.elaborate(RegFIFO8)}
    end

    test "elaborates and emits Verilog", %{design: design} do
      assert String.contains?(Hw.emit(design), "always @(posedge")
    end

    test "memoryless — no MemWrite ops", %{design: design} do
      refute Enum.any?(design.ops, &match?(%Hw.IR.Ops.MemWrite{}, &1))
    end
  end

  test "first-word-fall-through, including slot r0" do
    sim = start_dut()
    push(sim, 0xDEAD)
    assert Hw.Sim.get(sim, :rd_data) == 0xDEAD
    push(sim, 0xBEEF)
    assert pop(sim) == 0xDEAD
    assert pop(sim) == 0xBEEF
    assert Hw.Sim.get(sim, :empty) == 1
  end

  test "order preserved across several pointer wraps" do
    sim = start_dut()

    out =
      Enum.flat_map(0..5, fn batch ->
        Enum.each(0..3, fn n -> push(sim, batch * 4 + n + 1) end)
        Enum.map(0..3, fn _ -> pop(sim) end)
      end)

    assert out == Enum.to_list(1..24)
    assert Hw.Sim.get(sim, :empty) == 1
  end

  test "full at 8: the 9th write is dropped, contents intact" do
    sim = start_dut()
    Enum.each(1..8, fn n -> push(sim, n) end)
    assert Hw.Sim.get(sim, :full) == 1
    push(sim, 0xFFFF)
    assert Hw.Sim.get(sim, :count) == 8
    assert Enum.map(1..8, fn _ -> pop(sim) end) == Enum.to_list(1..8)
  end

  test "read while empty is ignored; FIFO still works after" do
    sim = start_dut()
    Hw.Sim.set(sim, :rd_en, 1)
    Hw.Sim.tick(sim, :clk, 3)
    Hw.Sim.set(sim, :rd_en, 0)
    assert Hw.Sim.get(sim, :count) == 0
    push(sim, 42)
    assert pop(sim) == 42
  end

  test "simultaneous read and write holds count, preserves order" do
    sim = start_dut()
    push(sim, 1)
    push(sim, 2)

    out =
      Enum.map(3..10, fn n ->
        head = Hw.Sim.get(sim, :rd_data)
        Hw.Sim.set(sim, :wr_en, 1)
        Hw.Sim.set(sim, :wr_data, n)
        Hw.Sim.set(sim, :rd_en, 1)
        Hw.Sim.tick(sim, :clk, 1)
        Hw.Sim.set(sim, :wr_en, 0)
        Hw.Sim.set(sim, :rd_en, 0)
        assert Hw.Sim.get(sim, :count) == 2
        head
      end)

    assert out == Enum.to_list(1..8)
    assert pop(sim) == 9
    assert pop(sim) == 10
  end
end
