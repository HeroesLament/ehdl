defmodule RegFIFO16Test do
  use ExUnit.Case
  @moduletag timeout: :infinity

  alias Hw.RegFIFO16

  # ---------------------------------------------------------------------------
  # Hw.RegFIFO16 — register-file FWFT FIFO for the HP0 stream path
  #
  # The invariants Hw.AXIHPWriter's head-of-queue contract rides on:
  # rd_data is combinationally the oldest word (first-word-fall-through),
  # rd_en consumes exactly one word, order is preserved across pointer
  # wraps, and full/empty guards make overruns drops rather than
  # corruption.
  # ---------------------------------------------------------------------------

  defp start_dut do
    {:ok, sim} = Hw.Sim.start(RegFIFO16)
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
      {:ok, design: Hw.Compile.Elaborate.elaborate(RegFIFO16)}
    end

    test "elaborates and emits Verilog", %{design: design} do
      verilog = Hw.emit(design)
      assert String.contains?(verilog, "always @(posedge")
    end

    test "memoryless — no MemWrite ops, so compositions stay simulable", %{design: design} do
      refute Enum.any?(design.ops, &match?(%Hw.IR.Ops.MemWrite{}, &1))
    end
  end

  test "first-word-fall-through: the head is on rd_data with no rd_en" do
    sim = start_dut()
    assert Hw.Sim.get(sim, :empty) == 1

    push(sim, 0xDEAD)
    assert Hw.Sim.get(sim, :empty) == 0
    assert Hw.Sim.get(sim, :count) == 1
    assert Hw.Sim.get(sim, :rd_data) == 0xDEAD

    push(sim, 0xBEEF)
    # Head unchanged until consumed.
    assert Hw.Sim.get(sim, :rd_data) == 0xDEAD
    assert pop(sim) == 0xDEAD
    assert Hw.Sim.get(sim, :rd_data) == 0xBEEF
    assert pop(sim) == 0xBEEF
    assert Hw.Sim.get(sim, :empty) == 1
  end

  test "order preserved across several pointer wraps" do
    sim = start_dut()

    # 48 words through a 16-deep FIFO in batches of 8: three full wraps.
    out =
      Enum.flat_map(0..5, fn batch ->
        Enum.each(0..7, fn n -> push(sim, batch * 8 + n + 1) end)
        Enum.map(0..7, fn _ -> pop(sim) end)
      end)

    assert out == Enum.to_list(1..48)
    assert Hw.Sim.get(sim, :empty) == 1
    assert Hw.Sim.get(sim, :count) == 0
  end

  test "full: the 17th write is dropped, contents and count intact" do
    sim = start_dut()
    Enum.each(1..16, fn n -> push(sim, n) end)
    assert Hw.Sim.get(sim, :full) == 1
    assert Hw.Sim.get(sim, :count) == 16

    push(sim, 0xFFFF)
    assert Hw.Sim.get(sim, :count) == 16

    assert Enum.map(1..16, fn _ -> pop(sim) end) == Enum.to_list(1..16)
    assert Hw.Sim.get(sim, :empty) == 1
  end

  test "read while empty is ignored" do
    sim = start_dut()
    Hw.Sim.set(sim, :rd_en, 1)
    Hw.Sim.tick(sim, :clk, 3)
    Hw.Sim.set(sim, :rd_en, 0)
    assert Hw.Sim.get(sim, :empty) == 1
    assert Hw.Sim.get(sim, :count) == 0

    # And the FIFO still works afterwards.
    push(sim, 42)
    assert pop(sim) == 42
  end

  test "simultaneous read and write holds count and preserves order" do
    sim = start_dut()
    push(sim, 1)
    push(sim, 2)

    # Streaming regime: one in, one out, every cycle.
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
