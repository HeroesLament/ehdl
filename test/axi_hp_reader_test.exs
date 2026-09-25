defmodule AXIHPReaderTest do
  use ExUnit.Case
  @moduletag timeout: :infinity

  alias Hw.AXIHPReader

  # ---------------------------------------------------------------------------
  # Hw.AXIHPReader: AXI3 HP read-burst engine (TX direction)
  #
  # Mirror of axi_hp_writer_test.exs. The test is the AXI slave (owns ARREADY,
  # RVALID/RDATA/RLAST/RRESP) and the sink (records m_data whenever m_wen is
  # high at a clock edge). Established here: one AR per burst, ARLEN, beats
  # pushed in order and only when accepted, ring arithmetic against head_addr,
  # the gating conditions, and the error counters. The PS7's real ARREADY /
  # RVALID timing is a silicon measurement, out of scope.
  # ---------------------------------------------------------------------------

  defp sig(design, name), do: Enum.find(design.signals, &(&1.name == name))

  describe "structure" do
    setup do
      {:ok, design: Hw.Compile.Elaborate.elaborate(AXIHPReader)}
    end

    test "elaborates to a clocked design and emits Verilog", %{design: design} do
      assert String.contains?(Hw.emit(design), "always @(posedge")
    end

    test "the read channel is AXI3-shaped for a Zynq HP port", %{design: design} do
      assert sig(design, :m_axi_arlen).width == 4
      assert sig(design, :m_axi_arsize).width == 2
      assert sig(design, :m_axi_arid).width == 6
      assert sig(design, :m_axi_rid).width == 6
      assert sig(design, :m_axi_rdata).width == 64
      assert sig(design, :m_axi_rresp).width == 2
      assert sig(design, :m_axi_arlock).width == 2
      assert sig(design, :m_axi_arcache).width == 4
      assert sig(design, :m_axi_arqos).width == 4
    end

    test "holds no sample storage, the FIFO composes behind it", %{design: design} do
      refute Enum.any?(design.ops, &match?(%Hw.IR.Ops.MemWrite{}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Behavioural
  # ---------------------------------------------------------------------------

  @base 0x0010_0000

  defp start_dut(opts \\ []) do
    {:ok, sim} = Hw.Sim.start(AXIHPReader)

    Hw.Sim.set(sim, :aresetn, 0)
    Hw.Sim.set(sim, :m_space, Keyword.get(opts, :m_space, 1))
    Hw.Sim.set(sim, :m_axi_arready, 0)
    Hw.Sim.set(sim, :m_axi_rvalid, 0)
    Hw.Sim.set(sim, :m_axi_rdata, 0)
    Hw.Sim.set(sim, :m_axi_rlast, 0)
    Hw.Sim.set(sim, :m_axi_rresp, 0)
    Hw.Sim.set(sim, :m_axi_rid, 0)
    Hw.Sim.set(sim, :base_addr, @base)
    Hw.Sim.set(sim, :ring_size, Keyword.get(opts, :ring_size, 0x1000))
    Hw.Sim.set(sim, :head_addr, Keyword.get(opts, :head_addr, @base))
    Hw.Sim.set(sim, :enable, Keyword.get(opts, :enable, 1))
    Hw.Sim.tick(sim, :aclk, 2)
    Hw.Sim.set(sim, :aresetn, 1)
    Hw.Sim.tick(sim, :aclk, 2)
    sim
  end

  # Wait for ARVALID, capture ARADDR/ARLEN, complete the handshake with a
  # one-cycle ARREADY pulse.
  defp accept_ar(sim) do
    :ok = Hw.Sim.wait_for(sim, :m_axi_arvalid, 1, clock: :aclk, max_ticks: 50)
    ar = {Hw.Sim.get(sim, :m_axi_araddr), Hw.Sim.get(sim, :m_axi_arlen)}
    Hw.Sim.set(sim, :m_axi_arready, 1)
    Hw.Sim.tick(sim, :aclk, 1)
    Hw.Sim.set(sim, :m_axi_arready, 0)
    ar
  end

  # Serve one burst as the R channel. Each beat is held on RVALID until the
  # DUT accepts it (RREADY high at an edge). `gap: true` inserts one idle
  # cycle (RVALID low) before every beat. Returns what the sink received:
  # m_data sampled at every edge where m_wen was high.
  defp serve_burst(sim, words, opts \\ []) do
    gap = Keyword.get(opts, :gap, false)
    resp = Keyword.get(opts, :rresp, 0)
    last_at = Keyword.get(opts, :rlast_at, length(words) - 1)

    sink =
      words
      |> Enum.with_index()
      |> Enum.reduce([], fn {w, i}, sink ->
        sink =
          if gap do
            Hw.Sim.set(sim, :m_axi_rvalid, 0)
            edge(sim, sink)
          else
            sink
          end

        Hw.Sim.set(sim, :m_axi_rvalid, 1)
        Hw.Sim.set(sim, :m_axi_rdata, w)
        Hw.Sim.set(sim, :m_axi_rresp, resp)
        Hw.Sim.set(sim, :m_axi_rlast, if(i == last_at, do: 1, else: 0))
        hold_until_accepted(sim, sink, 20)
      end)

    Hw.Sim.set(sim, :m_axi_rvalid, 0)
    Hw.Sim.set(sim, :m_axi_rlast, 0)
    Hw.Sim.set(sim, :m_axi_rresp, 0)
    Enum.reverse(edge(sim, sink))
  end

  defp hold_until_accepted(_sim, _sink, 0), do: flunk("DUT never accepted an R beat")

  defp hold_until_accepted(sim, sink, budget) do
    accepted = Hw.Sim.get(sim, :m_axi_rready) == 1
    sink = edge(sim, sink)
    if accepted, do: sink, else: hold_until_accepted(sim, sink, budget - 1)
  end

  # One clock edge, recording the sink push that happens at it.
  defp edge(sim, sink) do
    pushed = if Hw.Sim.get(sim, :m_wen) == 1, do: [Hw.Sim.get(sim, :m_data) | sink], else: sink
    Hw.Sim.tick(sim, :aclk, 1)
    pushed
  end

  defp words(tag), do: Enum.map(0..15, &(tag + &1))

  test "a 16-word burst: one AR at the tail, ARLEN 15, beats pushed in order" do
    sim = start_dut(head_addr: @base + 128)

    assert {@base, 15} == accept_ar(sim)
    assert serve_burst(sim, words(0xA000)) == words(0xA000)

    assert Hw.Sim.get(sim, :read_ptr) == @base + 128
    assert Hw.Sim.get(sim, :bursts) == 1
    assert Hw.Sim.get(sim, :rresp_errs) == 0
    assert Hw.Sim.get(sim, :rlast_errs) == 0

    # Tail caught up with head: nothing more is readable.
    Hw.Sim.tick(sim, :aclk, 5)
    assert Hw.Sim.get(sim, :m_axi_arvalid) == 0
  end

  test "RVALID gaps push nothing and count nothing" do
    sim = start_dut(head_addr: @base + 128)

    accept_ar(sim)
    assert serve_burst(sim, words(0xB000), gap: true) == words(0xB000)
    assert Hw.Sim.get(sim, :bursts) == 1
    assert Hw.Sim.get(sim, :read_ptr) == @base + 128
  end

  test "no burst while disabled, without a full burst readable, or without sink space" do
    # Disabled.
    sim = start_dut(head_addr: @base + 128, enable: 0)
    Hw.Sim.tick(sim, :aclk, 5)
    assert Hw.Sim.get(sim, :m_axi_arvalid) == 0

    # Less than one burst between tail and head (producer wrote 96 B).
    Hw.Sim.set(sim, :enable, 1)
    Hw.Sim.set(sim, :head_addr, @base + 96)
    Hw.Sim.tick(sim, :aclk, 5)
    assert Hw.Sim.get(sim, :m_axi_arvalid) == 0

    # Full burst readable but the sink has no room.
    Hw.Sim.set(sim, :head_addr, @base + 128)
    Hw.Sim.set(sim, :m_space, 0)
    Hw.Sim.tick(sim, :aclk, 5)
    assert Hw.Sim.get(sim, :m_axi_arvalid) == 0

    # All three: the engine moves.
    Hw.Sim.set(sim, :m_space, 1)
    assert :ok == Hw.Sim.wait_for(sim, :m_axi_arvalid, 1, clock: :aclk, max_ticks: 10)
  end

  test "the tail wraps at ring_size, and head behind tail reads across the wrap" do
    # 256 B ring = two bursts. Producer has written the whole ring minus
    # nothing: head wrapped back to base, tail at base+128 after burst one.
    sim = start_dut(ring_size: 0x100, head_addr: @base + 128)

    assert {@base, 15} == accept_ar(sim)
    serve_burst(sim, words(0xC000))
    assert Hw.Sim.get(sim, :read_ptr) == @base + 128

    Hw.Sim.set(sim, :head_addr, @base)
    assert {a1, 15} = accept_ar(sim)
    assert a1 == @base + 128
    assert serve_burst(sim, words(0xC100)) == words(0xC100)

    assert Hw.Sim.get(sim, :read_ptr) == @base
    assert Hw.Sim.get(sim, :bursts) == 2

    # Tail == head again: empty.
    Hw.Sim.tick(sim, :aclk, 5)
    assert Hw.Sim.get(sim, :m_axi_arvalid) == 0
  end

  test "back-to-back bursts while more than one burst is readable" do
    sim = start_dut(head_addr: @base + 256)

    assert {@base, 15} == accept_ar(sim)
    assert serve_burst(sim, words(0xD000)) == words(0xD000)
    assert {a1, 15} = accept_ar(sim)
    assert a1 == @base + 128
    assert serve_burst(sim, words(0xD100)) == words(0xD100)
    assert Hw.Sim.get(sim, :bursts) == 2
  end

  test "an SLVERR is counted per beat and the tail still advances" do
    sim = start_dut(head_addr: @base + 128)

    accept_ar(sim)
    assert length(serve_burst(sim, words(0xE000), rresp: 2)) == 16
    assert Hw.Sim.get(sim, :rresp_errs) == 16
    assert Hw.Sim.get(sim, :read_ptr) == @base + 128
  end

  test "RLAST on the wrong beat is counted; the engine follows its own count" do
    sim = start_dut(head_addr: @base + 128)

    accept_ar(sim)
    # Slave asserts RLAST on beat 7 instead of 15: beat 7 and beat 15 both
    # mismatch (RLAST high early, then low on the real last beat).
    assert serve_burst(sim, words(0xF000), rlast_at: 7) == words(0xF000)
    assert Hw.Sim.get(sim, :rlast_errs) == 2
    assert Hw.Sim.get(sim, :bursts) == 1
  end
end
