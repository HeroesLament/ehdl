defmodule AD936xFramePackerTest do
  use ExUnit.Case
  @moduletag timeout: :infinity

  alias Hw.AD936xFramePacker

  # ---------------------------------------------------------------------------
  # Hw.AD936xFramePacker — LVDS frame walk -> 64-bit self-framing stream words
  #
  # The tests drive the packer with the measured RX_FRAME cycle [3,1,0,2]
  # (frame_pair = {fall, rise}, pulse mode) and check that field selection
  # matches Nervezynq.MIMO.decode/2 exactly: I1 = sample_b at pair 3,
  # Q1 = sample_a at pair 1, I2 = sample_b at pair 0, Q2 = sample_a at pair 2.
  # Sequence continuity, toggle discipline, resync behaviour and the ERR bit
  # are the invariants the DMA path's gapless claim rests on.
  # ---------------------------------------------------------------------------

  defp start_dut do
    {:ok, sim} = Hw.Sim.start(AD936xFramePacker)
    Hw.Sim.set(sim, :enable, 0)
    Hw.Sim.set(sim, :sample_a, 0)
    Hw.Sim.set(sim, :sample_b, 0)
    Hw.Sim.set(sim, :frame_pair, 0)
    Hw.Sim.tick(sim, :clk, 2)
    Hw.Sim.set(sim, :enable, 1)
    Hw.Sim.tick(sim, :clk, 1)
    sim
  end

  # One DATA_CLK cycle: present {frame_pair, sample_a, sample_b}, clock it in.
  defp cycle(sim, fp, sa, sb) do
    Hw.Sim.set(sim, :frame_pair, fp)
    Hw.Sim.set(sim, :sample_a, sa)
    Hw.Sim.set(sim, :sample_b, sb)
    Hw.Sim.tick(sim, :clk, 1)
  end

  # Feed one whole frame. The off-field sample inputs carry poison values so
  # a wrong field selection cannot pass by accident.
  defp frame(sim, {i1, q1, i2, q2}) do
    cycle(sim, 3, 0xAAA, i1)
    cycle(sim, 1, q1, 0x555)
    cycle(sim, 0, 0xAAA, i2)
    cycle(sim, 2, q2, 0x555)
  end

  defp unpack(w) do
    <<rsv::1, err::1, seq::14, q2::12, i2::12, q1::12, i1::12>> = <<w::64>>
    %{rsv: rsv, err: err, seq: seq, i1: i1, q1: q1, i2: i2, q2: q2}
  end

  defp word(sim), do: unpack(Hw.Sim.get(sim, :word))

  describe "structure" do
    setup do
      {:ok, design: Hw.Compile.Elaborate.elaborate(AD936xFramePacker)}
    end

    test "elaborates to a clocked design and emits Verilog", %{design: design} do
      verilog = Hw.emit(design)
      assert String.contains?(verilog, "always @(posedge")
    end

    test "memoryless — the composition with the FIFO stays simulable", %{design: design} do
      refute Enum.any?(design.ops, &match?(%Hw.IR.Ops.MemWrite{}, &1))
    end
  end

  test "one frame packs with MIMO.decode field selection, SEQ 0, toggle flip" do
    sim = start_dut()
    t0 = Hw.Sim.get(sim, :word_toggle)

    frame(sim, {0x123, 0x456, 0x789, 0xABC})

    assert Hw.Sim.get(sim, :word_toggle) == 1 - t0
    w = word(sim)
    assert w.i1 == 0x123
    assert w.q1 == 0x456
    assert w.i2 == 0x789
    assert w.q2 == 0xABC
    assert w.seq == 0
    assert w.err == 0
    assert w.rsv == 0
    assert Hw.Sim.get(sim, :sync_lost) == 0
  end

  test "SEQ increments per frame and the toggle alternates" do
    sim = start_dut()

    toggles =
      for n <- 0..4 do
        frame(sim, {n, n + 1, n + 2, n + 3})
        assert word(sim).seq == n
        Hw.Sim.get(sim, :word_toggle)
      end

    assert toggles == [1, 0, 1, 0, 1]
  end

  test "a capture starting mid-frame waits for frame start without flagging" do
    sim = start_dut()
    t0 = Hw.Sim.get(sim, :word_toggle)

    # Enable landed mid-frame: tail of someone else's frame drifts past.
    cycle(sim, 1, 0xFFF, 0xFFF)
    cycle(sim, 0, 0xFFF, 0xFFF)
    cycle(sim, 2, 0xFFF, 0xFFF)

    assert Hw.Sim.get(sim, :word_toggle) == t0
    assert Hw.Sim.get(sim, :sync_lost) == 0

    frame(sim, {1, 2, 3, 4})
    assert Hw.Sim.get(sim, :word_toggle) == 1 - t0
    w = word(sim)
    assert {w.i1, w.q1, w.i2, w.q2} == {1, 2, 3, 4}
    assert w.seq == 0
    assert w.err == 0
  end

  test "a frame start mid-assembly drops the partial frame and marks the next word" do
    sim = start_dut()

    # Frame begins, then RX_FRAME restarts two cycles in.
    cycle(sim, 3, 0xAAA, 0x111)
    cycle(sim, 1, 0x222, 0x555)

    frame(sim, {5, 6, 7, 8})

    assert Hw.Sim.get(sim, :sync_lost) == 1
    w = word(sim)
    assert {w.i1, w.q1, w.i2, w.q2} == {5, 6, 7, 8}
    # The torn frame emitted nothing; this is still SEQ 0, flagged ERR.
    assert w.seq == 0
    assert w.err == 1

    # The following frame is clean again; sync_lost stays sticky.
    frame(sim, {9, 10, 11, 12})
    w = word(sim)
    assert w.seq == 1
    assert w.err == 0
    assert Hw.Sim.get(sim, :sync_lost) == 1
  end

  test "an out-of-cycle frame value mid-assembly tears the frame" do
    sim = start_dut()

    cycle(sim, 3, 0xAAA, 0x111)
    # Expected 1, got 2: torn.
    cycle(sim, 2, 0xBBB, 0xCCC)
    assert Hw.Sim.get(sim, :sync_lost) == 1

    frame(sim, {5, 6, 7, 8})
    w = word(sim)
    assert w.seq == 0
    assert w.err == 1
  end

  test "disable clears SEQ and flags but never glitches the toggle" do
    sim = start_dut()

    frame(sim, {1, 2, 3, 4})
    frame(sim, {5, 6, 7, 8})
    t = Hw.Sim.get(sim, :word_toggle)
    assert word(sim).seq == 1

    Hw.Sim.set(sim, :enable, 0)
    Hw.Sim.tick(sim, :clk, 3)
    assert Hw.Sim.get(sim, :word_toggle) == t
    assert Hw.Sim.get(sim, :sync_lost) == 0

    Hw.Sim.set(sim, :enable, 1)
    Hw.Sim.tick(sim, :clk, 1)
    frame(sim, {9, 10, 11, 12})
    w = word(sim)
    assert w.seq == 0
    assert Hw.Sim.get(sim, :word_toggle) == 1 - t
  end
end
