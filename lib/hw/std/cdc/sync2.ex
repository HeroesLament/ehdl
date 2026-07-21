defmodule Hw.CDC.Sync2 do
  @moduledoc """
  Two-flop synchronizer for single-bit CDC crossings.

  The standard safe crossing for a single-bit signal moving from one clock
  domain to another. Two back-to-back registers in the destination domain
  reduce the probability of metastability to negligible levels.

      src_domain          dst_domain
      ─────────           ──────────
      [Reg clk_a] ──────> [FF1 clk_b] ──> [FF2 clk_b] ──> data_out

  ## Usage

      instance :sync_rx, Hw.CDC.Sync2,
        clk_dst: :clk_200,
        rst:     :rst,
        data_in: :phy_rx_valid,    # driven by clk_48 domain
        data_out: :sie_rx_valid    # safe to use in clk_200 domain

  ## Notes

  - Only safe for **single-bit** signals. Multi-bit signals that must be
    coherent require `Hw.CDC.HandshakeSync` or `Hw.CDC.FIFO`.
  - The output `data_out` is registered twice in `clk_dst`, so there is a
    2-cycle latency from input to output.
  - The signal `data_out` is automatically whitelisted in the CDC validator
    as a safe crossing — no false positive errors.

  ## Parameters

  - `STAGES` — number of synchronizer flops (default: 2, minimum: 2)
  """

  use Hw.Component

  param :STAGES, default: 2

  clock :clk_dst
  input  :rst,      1
  input  :data_in,  1
  output :data_out, 1

  # Internal pipeline registers
  # ff[0] captures the async input, ff[1] is the stable output
  wire :ff0, 1, init: 0
  wire :ff1, 1, init: 0

  # Stage 0: capture async input — may go metastable but resolves within cycle
  on :clk_dst do
    if rst do
      ff0 = 0
    else
      ff0 = data_in
    end
  end

  # Stage 1: re-register — metastability resolved, output is stable
  on :clk_dst do
    if rst do
      ff1 = 0
    else
      ff1 = ff0
    end
  end

  comb do
    data_out = ff1
  end
end
