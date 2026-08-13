defmodule LibreSDRLvdsSpike.Top do
  @moduledoc """
  A throwaway design whose only purpose is to answer one question: can the
  openXC7 flow build a differential, double-data-rate input on this part?

  Everything in path 1 — the whole AD9363 sample interface — depends on
  `IBUFDS` and `IDDR` working end to end: yosys must keep them, nextpnr-xilinx
  must pack them into the IOB and ILOGIC sites, and `fasm.cc` must emit the
  right features for `fasm2frames` to turn into bits. Those tiles are the least
  mature corner of the flow. If this design does not build, no amount of work
  on the DSP side gets samples off the radio, and the fix is a contribution to
  nextpnr-xilinx rather than to anything here.

  So: build it, note precisely where it fails if it fails, and only then decide
  what the project is actually doing next.

  ## What it is

      DATA_CLK pair -> IBUFDS -> BUFG ------> clock domain
      RX_D0 pair    -> IBUFDS -> IDDR -----> Q1, Q2
                                     |
                                     +--> XOR -> counter enable
                                                    |
                                     counter[23] ---+--> OBUF -> PL_LED0

  The XOR matters. Without something consuming both IDDR outputs, synthesis is
  entitled to delete the whole thing, and a design that builds because it was
  optimised away answers no question at all. Gating a counter on Q1 != Q2 keeps
  both halves live and makes the output depend on real captured data.

  ## Not for loading

  This is a toolchain probe, not firmware. It constrains bank 34 as `LVDS_25`,
  which is right if the board powers that bank at 2.5 V — the schematic shows
  `+2.5V_A` on the AD9363 section, but that has not been measured. Confirm the
  bank voltage before driving anything.

  Both halves of each pair carry a `PACKAGE_PIN` constraint. Vivado infers the
  N pin from the P pin; nextpnr-xilinx does not, and both are real ports in the
  netlist here.
  """

  use Hw.Component

  # AD9363 receive interface, bank 34.
  #   DATA_CLK  N20/P20  IO_L14P/N_T2_SRCC_34   (clock capable, as it must be)
  #   RX_D0     Y18/Y19  IO_L17P/N_T2_34
  input :ad9363_data_clk_p, 1
  input :ad9363_data_clk_n, 1
  input :ad9363_rx_d0_p, 1
  input :ad9363_rx_d0_n, 1

  # Bank 35, so its VCCO is independent of the LVDS bank.
  output :pl_led0, 1

  wire :data_clk_raw, 1
  wire :data_clk, 1
  wire :rx_d0, 1
  wire :q1, 1
  wire :q2, 1
  wire :led, 1
  wire :edge_seen, 1
  wire :tie0, 1
  wire :tie1, 1

  wire :counter, 24, init: 0

  # DATA_CLK is 4x the sample rate on a 2R2T LVDS bus, so a HaLow-appropriate
  # 4 MSPS puts this at 16 MHz. Constrained higher to leave the timing question
  # open — the point of the spike is whether it builds, not how fast.
  clock :data_clk, freq: 50.0

  instance :clk_ibufds, Hw.Xilinx.IBUFDS,
    i: :ad9363_data_clk_p,
    ib: :ad9363_data_clk_n,
    o: :data_clk_raw

  instance :clk_bufg, Hw.Xilinx.BUFG,
    i: :data_clk_raw,
    o: :data_clk

  instance :d0_ibufds, Hw.Xilinx.IBUFDS,
    i: :ad9363_rx_d0_p,
    ib: :ad9363_rx_d0_n,
    o: :rx_d0

  instance :d0_iddr, Hw.Xilinx.IDDR,
    c: :data_clk,
    ce: :tie1,
    d: :rx_d0,
    r: :tie0,
    s: :tie0,
    q1: :q1,
    q2: :q2

  instance :led_obuf, Hw.Xilinx.OBUF,
    i: :led,
    o: :pl_led0

  comb do
    tie0 = 0
    tie1 = 1

    # Both IDDR outputs must be consumed or the design folds to nothing.
    edge_seen = bxor(q1, q2)

    led = counter[23..23]
  end

  on :data_clk do
    if edge_seen == 1 do
      counter = counter + 1
    end
  end
end
