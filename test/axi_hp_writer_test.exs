defmodule AXIHPWriterTest do
  use ExUnit.Case
  @moduletag timeout: :infinity

  alias Hw.AXIHPWriter

  # ---------------------------------------------------------------------------
  # Hw.AXIHPWriter — AXI3 HP write-burst engine
  #
  # The behavioural tests drive the DUT against a scripted AXI slave and a
  # scripted head-of-queue source: the test owns AWREADY/WREADY/BVALID and
  # plays the FIFO (advance s_data when s_ren is high). What these tests
  # establish is that the engine follows AXI3 — one AW per burst, exactly
  # BURST_LEN beats, WLAST on the final beat, data consumed in order, ring
  # arithmetic — against an ideal slave. The PS7's real AWREADY/WREADY
  # behaviour is a hardware measurement, deliberately out of scope here
  # (HP0 is UNV in SILICON_MAP terms).
  # ---------------------------------------------------------------------------

  defp sig(design, name), do: Enum.find(design.signals, &(&1.name == name))

  describe "structure" do
    setup do
      {:ok, design: Hw.Compile.Elaborate.elaborate(AXIHPWriter)}
    end

    test "elaborates to a clocked design and emits Verilog", %{design: design} do
      verilog = Hw.emit(design)
      assert String.contains?(verilog, "always @(posedge")
    end

    test "the write channel is AXI3-shaped for a Zynq HP port", %{design: design} do
      # AXI3, not AXI4: 4-bit LEN, and WID exists (HP matches W beats to
      # their address by ID). AWSIZE is the PS7 primitive's 2-bit field.
      assert sig(design, :m_axi_awlen).width == 4
      assert sig(design, :m_axi_awsize).width == 2
      assert sig(design, :m_axi_awid).width == 6
      assert sig(design, :m_axi_wid).width == 6
      assert sig(design, :m_axi_bid).width == 6
      assert sig(design, :m_axi_wdata).width == 64
      assert sig(design, :m_axi_wstrb).width == 8
      assert sig(design, :m_axi_awlock).width == 2
      assert sig(design, :m_axi_awcache).width == 4
      assert sig(design, :m_axi_awqos).width == 4
    end

    test "holds no sample storage — the FIFO composes in front", %{design: design} do
      # The simulator cannot execute MemWrite yet (see the moduledoc), so an
      # internal memory would make this component untestable. This pin keeps
      # a future "just add a small internal buffer" from silently regressing
      # the testability of the one component that talks to the PS.
      refute Enum.any?(design.ops, &match?(%Hw.IR.Ops.MemWrite{}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Behavioural
  # ---------------------------------------------------------------------------

  @base 0x0010_0000

  defp start_dut(opts \\ []) do
    ring = Keyword.get(opts, :ring_size, 0x1000)
    {:ok, sim} = Hw.Sim.start(AXIHPWriter)

    Hw.Sim.set(sim, :aresetn, 0)
    Hw.Sim.set(sim, :s_data, 0)
    Hw.Sim.set(sim, :s_avail, 0)
    Hw.Sim.set(sim, :m_axi_awready, 0)
    Hw.Sim.set(sim, :m_axi_wready, 0)
    Hw.Sim.set(sim, :m_axi_bvalid, 0)
    Hw.Sim.set(sim, :m_axi_bresp, 0)
    Hw.Sim.set(sim, :m_axi_bid, 0)
    Hw.Sim.set(sim, :base_addr, @base)
    Hw.Sim.set(sim, :ring_size, ring)
    Hw.Sim.set(sim, :enable, 1)
    Hw.Sim.tick(sim, :aclk, 2)
    Hw.Sim.set(sim, :aresetn, 1)
    Hw.Sim.tick(sim, :aclk, 2)
    sim
  end

  # Scripted FIFO: present head, advance on s_ren. Returns leftover queue.
  # One tick per call; also samples the W channel, appending accepted beats.
  defp source_tick(sim, queue, wready) do
    v = Hw.Sim.get(sim, :m_axi_wvalid)
    d = Hw.Sim.get(sim, :m_axi_wdata)
    l = Hw.Sim.get(sim, :m_axi_wlast)
    ren = Hw.Sim.get(sim, :s_ren)

    Hw.Sim.tick(sim, :aclk, 1)

    accepted = if v == 1 and wready == 1, do: [{d, l}], else: []

    queue =
      if ren == 1 do
        rest = tl(queue)
        Hw.Sim.set(sim, :s_data, List.first(rest, 0))
        Hw.Sim.set(sim, :s_avail, (if length(rest) >= 16, do: 1, else: 0))
        rest
      else
        queue
      end

    {queue, accepted}
  end

  defp load_source(sim, words) do
    Hw.Sim.set(sim, :s_data, hd(words))
    Hw.Sim.set(sim, :s_avail, (if length(words) >= 16, do: 1, else: 0))
    words
  end

  # Accept one full burst as an ideal slave; returns {awaddr, beats, queue}.
  defp accept_burst(sim, queue) do
    :ok = Hw.Sim.wait_for(sim, :m_axi_awvalid, 1, clock: :aclk, max_ticks: 50)
    awaddr = Hw.Sim.get(sim, :m_axi_awaddr)

    # One-cycle AWREADY pulse; AWVALID was already high, so the handshake
    # completes on this edge.
    Hw.Sim.set(sim, :m_axi_awready, 1)
    Hw.Sim.tick(sim, :aclk, 1)
    Hw.Sim.set(sim, :m_axi_awready, 0)

    Hw.Sim.set(sim, :m_axi_wready, 1)
    {queue, beats} = collect_beats(sim, queue, [], 200)
    Hw.Sim.set(sim, :m_axi_wready, 0)

    # Write response. in_wait_resp is registered (low on the state's first
    # cycle), so hold BVALID across two edges.
    Hw.Sim.set(sim, :m_axi_bvalid, 1)
    Hw.Sim.tick(sim, :aclk, 2)
    Hw.Sim.set(sim, :m_axi_bvalid, 0)
    Hw.Sim.tick(sim, :aclk, 1)

    {awaddr, beats, queue}
  end

  defp collect_beats(_sim, queue, beats, 0), do: {queue, beats}

  defp collect_beats(sim, queue, beats, budget) do
    {queue, accepted} = source_tick(sim, queue, 1)
    beats = beats ++ accepted

    done = beats != [] and elem(List.last(beats), 1) == 1 and accepted != []

    if done, do: {queue, beats}, else: collect_beats(sim, queue, beats, budget - 1)
  end

  test "a 16-word burst has AXI3 shape: one address, 16 beats in order, WLAST on the last" do
    sim = start_dut()
    words = Enum.map(0..15, &(0xA000 + &1))
    queue = load_source(sim, words)

    {awaddr, beats, queue} = accept_burst(sim, queue)

    assert awaddr == @base
    assert length(beats) == 16
    assert Enum.map(beats, &elem(&1, 0)) == words

    # WLAST exactly once, on the final beat.
    assert Enum.map(beats, &elem(&1, 1)) == List.duplicate(0, 15) ++ [1]

    # The source was drained exactly once per beat.
    assert queue == []

    # Bookkeeping after the response: one burst, pointer advanced 128 bytes,
    # no errors.
    assert Hw.Sim.get(sim, :write_ptr) == @base + 128
    assert Hw.Sim.get(sim, :bursts) == 1
    assert Hw.Sim.get(sim, :bresp_errs) == 0

    # And with the source empty, no second address appears.
    Hw.Sim.tick(sim, :aclk, 5)
    assert Hw.Sim.get(sim, :m_axi_awvalid) == 0
  end

  test "WVALID holds and neither data nor source advance while WREADY is low" do
    sim = start_dut()
    queue = load_source(sim, Enum.map(0..15, &(0xB000 + &1)))

    :ok = Hw.Sim.wait_for(sim, :m_axi_awvalid, 1, clock: :aclk, max_ticks: 50)
    Hw.Sim.set(sim, :m_axi_awready, 1)
    Hw.Sim.tick(sim, :aclk, 1)
    Hw.Sim.set(sim, :m_axi_awready, 0)

    # Accept two beats, then stall the W channel.
    Hw.Sim.set(sim, :m_axi_wready, 1)
    :ok = Hw.Sim.wait_for(sim, :m_axi_wvalid, 1, clock: :aclk, max_ticks: 20)
    {queue, _} = source_tick(sim, queue, 1)
    {queue, _} = source_tick(sim, queue, 1)
    Hw.Sim.set(sim, :m_axi_wready, 0)

    held = Hw.Sim.get(sim, :m_axi_wdata)
    depth_before = length(queue)

    queue =
      Enum.reduce(1..4, queue, fn _, q ->
        assert Hw.Sim.get(sim, :m_axi_wvalid) == 1
        assert Hw.Sim.get(sim, :m_axi_wdata) == held
        assert Hw.Sim.get(sim, :s_ren) == 0
        {q, _} = source_tick(sim, q, 0)
        q
      end)

    assert length(queue) == depth_before
  end

  test "the ring pointer wraps at ring_size and returns to base" do
    # 256-byte ring = exactly two 128-byte bursts.
    sim = start_dut(ring_size: 0x100)
    queue = load_source(sim, Enum.map(0..31, &(0xC000 + &1)))

    {a0, b0, queue} = accept_burst(sim, queue)
    {a1, b1, _queue} = accept_burst(sim, queue)

    assert a0 == @base
    assert a1 == @base + 128
    assert length(b0) == 16 and length(b1) == 16

    # After the second response the pointer is back at base.
    assert Hw.Sim.get(sim, :write_ptr) == @base
    assert Hw.Sim.get(sim, :bursts) == 2
  end

  test "no burst starts until a full burst is available, or while disabled" do
    sim = start_dut()

    # Available but disabled.
    load_source(sim, Enum.map(0..15, &(0xD000 + &1)))
    Hw.Sim.set(sim, :enable, 0)
    Hw.Sim.tick(sim, :aclk, 5)
    assert Hw.Sim.get(sim, :m_axi_awvalid) == 0

    # Enabled but under threshold.
    Hw.Sim.set(sim, :enable, 1)
    Hw.Sim.set(sim, :s_avail, 0)
    Hw.Sim.tick(sim, :aclk, 5)
    assert Hw.Sim.get(sim, :m_axi_awvalid) == 0

    # Both — the engine moves.
    Hw.Sim.set(sim, :s_avail, 1)
    assert :ok == Hw.Sim.wait_for(sim, :m_axi_awvalid, 1, clock: :aclk, max_ticks: 10)
  end

  test "a SLVERR response is counted, not fatal" do
    sim = start_dut()
    queue = load_source(sim, Enum.map(0..15, &(0xE000 + &1)))

    Hw.Sim.set(sim, :m_axi_bresp, 2)
    {_awaddr, beats, _queue} = accept_burst(sim, queue)

    assert length(beats) == 16
    assert Hw.Sim.get(sim, :bresp_errs) == 1
    # The ring still advances — a slave error must not stall the stream.
    assert Hw.Sim.get(sim, :write_ptr) == @base + 128
  end
end
