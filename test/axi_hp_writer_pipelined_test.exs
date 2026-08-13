defmodule AXIHPWriterPipelinedTest do
  use ExUnit.Case
  @moduletag timeout: :infinity

  # ---------------------------------------------------------------------------
  # Hw.AXIHPWriter with PIPELINED_SOURCE: 1 — the mode Hw.StreamBRAMFIFO needs.
  #
  # The scripted source here models a sync-read BRAM exactly: the word a
  # strobe selects appears on s_data TWO ticks after the strobe is observed
  # (pointer registers on the strobe edge, BRAM output registers on the
  # next). The engine must therefore never accept beats on consecutive
  # cycles — the WVALID 1,0 gap discipline — and the data assertions catch
  # any duplicate or skipped word if it ever does.
  # ---------------------------------------------------------------------------

  defmodule Harness do
    @moduledoc false
    use Hw.Component

    clock :aclk, freq: 100.0
    input :aresetn, 1

    input :s_data, 64
    input :s_avail, 1
    output :s_ren, 1

    input :base_addr, 32
    input :ring_size, 32
    input :enable, 1

    output :write_ptr, 32
    output :bursts, 16
    output :bresp_errs, 8

    output :m_axi_awid, 6
    output :m_axi_awaddr, 32
    output :m_axi_awlen, 4
    output :m_axi_awsize, 2
    output :m_axi_awburst, 2
    output :m_axi_awlock, 2
    output :m_axi_awcache, 4
    output :m_axi_awprot, 3
    output :m_axi_awqos, 4
    output :m_axi_awvalid, 1
    input :m_axi_awready, 1

    output :m_axi_wid, 6
    output :m_axi_wdata, 64
    output :m_axi_wstrb, 8
    output :m_axi_wlast, 1
    output :m_axi_wvalid, 1
    input :m_axi_wready, 1

    input :m_axi_bid, 6
    input :m_axi_bresp, 2
    input :m_axi_bvalid, 1
    output :m_axi_bready, 1

    instance :dma, Hw.AXIHPWriter,
      PIPELINED_SOURCE: 1,
      aclk: :aclk,
      aresetn: :aresetn,
      s_data: :s_data,
      s_avail: :s_avail,
      s_ren: :s_ren,
      base_addr: :base_addr,
      ring_size: :ring_size,
      enable: :enable,
      write_ptr: :write_ptr,
      bursts: :bursts,
      bresp_errs: :bresp_errs,
      m_axi_awid: :m_axi_awid,
      m_axi_awaddr: :m_axi_awaddr,
      m_axi_awlen: :m_axi_awlen,
      m_axi_awsize: :m_axi_awsize,
      m_axi_awburst: :m_axi_awburst,
      m_axi_awlock: :m_axi_awlock,
      m_axi_awcache: :m_axi_awcache,
      m_axi_awprot: :m_axi_awprot,
      m_axi_awqos: :m_axi_awqos,
      m_axi_awvalid: :m_axi_awvalid,
      m_axi_awready: :m_axi_awready,
      m_axi_wid: :m_axi_wid,
      m_axi_wdata: :m_axi_wdata,
      m_axi_wstrb: :m_axi_wstrb,
      m_axi_wlast: :m_axi_wlast,
      m_axi_wvalid: :m_axi_wvalid,
      m_axi_wready: :m_axi_wready,
      m_axi_bid: :m_axi_bid,
      m_axi_bresp: :m_axi_bresp,
      m_axi_bvalid: :m_axi_bvalid,
      m_axi_bready: :m_axi_bready
  end

  @base 0x0010_0000

  defp start_dut do
    {:ok, sim} = Hw.Sim.start(Harness)

    Hw.Sim.set(sim, :aresetn, 0)
    Hw.Sim.set(sim, :s_data, 0)
    Hw.Sim.set(sim, :s_avail, 0)
    Hw.Sim.set(sim, :m_axi_awready, 0)
    Hw.Sim.set(sim, :m_axi_wready, 0)
    Hw.Sim.set(sim, :m_axi_bvalid, 0)
    Hw.Sim.set(sim, :m_axi_bresp, 0)
    Hw.Sim.set(sim, :m_axi_bid, 0)
    Hw.Sim.set(sim, :base_addr, @base)
    Hw.Sim.set(sim, :ring_size, 0x1000)
    Hw.Sim.set(sim, :enable, 1)
    Hw.Sim.tick(sim, :aclk, 2)
    Hw.Sim.set(sim, :aresetn, 1)
    Hw.Sim.tick(sim, :aclk, 2)
    sim
  end

  defp load_source(sim, words) do
    Hw.Sim.set(sim, :s_data, hd(words))
    Hw.Sim.set(sim, :s_avail, (if length(words) >= 16, do: 1, else: 0))
    %{queue: words, pending: false}
  end

  # One tick of the BRAM-shaped source: a strobe observed this cycle
  # changes s_data only after the NEXT tick (registered pointer, then
  # registered BRAM output). Samples the W channel like the legacy test.
  defp pipe_tick(sim, st, wready) do
    v = Hw.Sim.get(sim, :m_axi_wvalid)
    d = Hw.Sim.get(sim, :m_axi_wdata)
    l = Hw.Sim.get(sim, :m_axi_wlast)
    ren = Hw.Sim.get(sim, :s_ren)

    Hw.Sim.tick(sim, :aclk, 1)

    st =
      if st.pending do
        rest = tl(st.queue)
        Hw.Sim.set(sim, :s_data, List.first(rest, 0))
        Hw.Sim.set(sim, :s_avail, (if length(rest) >= 16, do: 1, else: 0))
        %{st | queue: rest, pending: false}
      else
        st
      end

    st = if ren == 1, do: %{st | pending: true}, else: st

    accepted = if v == 1 and wready == 1, do: [{d, l}], else: []
    {st, accepted}
  end

  defp run_burst(sim, st, budget \\ 200) do
    :ok = Hw.Sim.wait_for(sim, :m_axi_awvalid, 1, clock: :aclk, max_ticks: 50)
    awaddr = Hw.Sim.get(sim, :m_axi_awaddr)

    Hw.Sim.set(sim, :m_axi_awready, 1)
    Hw.Sim.tick(sim, :aclk, 1)
    Hw.Sim.set(sim, :m_axi_awready, 0)

    Hw.Sim.set(sim, :m_axi_wready, 1)
    {st, trace} = collect(sim, st, [], budget)
    Hw.Sim.set(sim, :m_axi_wready, 0)

    Hw.Sim.set(sim, :m_axi_bvalid, 1)
    Hw.Sim.tick(sim, :aclk, 2)
    Hw.Sim.set(sim, :m_axi_bvalid, 0)
    Hw.Sim.tick(sim, :aclk, 1)

    {awaddr, trace, st}
  end

  # Collect per-cycle acceptance trace: {accepted?, data, last}.
  defp collect(_sim, st, trace, 0), do: {st, Enum.reverse(trace)}

  defp collect(sim, st, trace, budget) do
    {st, accepted} = pipe_tick(sim, st, 1)

    entry =
      case accepted do
        [{d, l}] -> {true, d, l}
        [] -> {false, nil, nil}
      end

    trace = [entry | trace]

    done =
      case entry do
        {true, _, 1} -> true
        _ -> false
      end

    if done, do: {st, Enum.reverse(trace)}, else: collect(sim, st, trace, budget - 1)
  end

  test "a pipelined burst: 16 beats, in order, never on consecutive cycles" do
    sim = start_dut()
    words = Enum.map(0..15, &(0xF0000 + &1))
    st = load_source(sim, words)

    {awaddr, trace, st} = run_burst(sim, st)

    beats = for {true, d, l} <- trace, do: {d, l}

    assert awaddr == @base
    assert length(beats) == 16
    assert Enum.map(beats, &elem(&1, 0)) == words
    assert Enum.map(beats, &elem(&1, 1)) == List.duplicate(0, 15) ++ [1]

    # The gap discipline: no two acceptances on adjacent cycles — the
    # cycle after every accepted beat must be a dead cycle.
    accepted_idx =
      trace |> Enum.with_index() |> Enum.filter(fn {{a, _, _}, _} -> a end) |> Enum.map(&elem(&1, 1))

    gaps = accepted_idx |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
    assert Enum.all?(gaps, &(&1 >= 2))

    # Exactly the burst was consumed, and the books balance. (The final
    # strobe's advance is still in flight when WLAST lands — one more tick
    # settles the source model.)
    {st, _} = pipe_tick(sim, st, 0)
    assert st.queue == []
    assert Hw.Sim.get(sim, :bursts) == 1
    assert Hw.Sim.get(sim, :bresp_errs) == 0
    assert Hw.Sim.get(sim, :write_ptr) == @base + 128
  end

  test "a WREADY stall mid-burst holds WVALID and data, and consumes nothing" do
    sim = start_dut()
    st = load_source(sim, Enum.map(0..15, &(0xA000 + &1)))

    :ok = Hw.Sim.wait_for(sim, :m_axi_awvalid, 1, clock: :aclk, max_ticks: 50)
    Hw.Sim.set(sim, :m_axi_awready, 1)
    Hw.Sim.tick(sim, :aclk, 1)
    Hw.Sim.set(sim, :m_axi_awready, 0)

    # Accept two beats, then stall.
    Hw.Sim.set(sim, :m_axi_wready, 1)
    {st, n} = accept_n(sim, st, 2, 40)
    assert n == 2
    Hw.Sim.set(sim, :m_axi_wready, 0)

    # Let WVALID re-assert after its post-beat gap, then observe the stall.
    {st, _} = pipe_tick(sim, st, 0)
    held = Hw.Sim.get(sim, :m_axi_wdata)
    depth = length(st.queue)

    st =
      Enum.reduce(1..4, st, fn _, acc ->
        assert Hw.Sim.get(sim, :m_axi_wvalid) == 1
        assert Hw.Sim.get(sim, :m_axi_wdata) == held
        assert Hw.Sim.get(sim, :s_ren) == 0
        {acc, _} = pipe_tick(sim, acc, 0)
        acc
      end)

    assert length(st.queue) == depth

    # Release the stall: the burst completes cleanly.
    Hw.Sim.set(sim, :m_axi_wready, 1)
    {st, trace} = collect(sim, st, [], 100)
    beats = for {true, d, l} <- trace, do: {d, l}
    assert length(beats) == 14
    {st, _} = pipe_tick(sim, st, 0)
    assert st.queue == []
  end

  defp accept_n(sim, st, want, budget), do: accept_n(sim, st, want, budget, 0)
  defp accept_n(_sim, st, want, 0, got), do: {st, min(got, want)}

  defp accept_n(sim, st, want, budget, got) do
    if got == want do
      {st, got}
    else
      {st, accepted} = pipe_tick(sim, st, 1)
      accept_n(sim, st, want, budget - 1, got + length(accepted))
    end
  end
end
