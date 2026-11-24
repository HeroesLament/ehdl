defmodule Hw.ECP5.DQSBUFM do
  @moduledoc """
  ECP5 `DQSBUFM`. DQS group strobe buffer: from the DQS pad, ECLK, SCLK and DDRDEL makes DQSR90 / DQSW / DQSW270 and the FIFO pointers for the group's DQ IOLOGIC. Must sit at the group's DQS pad.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/dqs_probe.v`: strobe and DQ drive, DATAVALID / BURSTDET, DQ loopback), not through this wrapper. The DDR tristates reach the pad only with the PIO TRIMUX_TSREG on IOLTO, which oxibit sets (nextpnr does not). Bring-up as LiteDRAM ECP5DDRPHYInit: DLL lock, freeze, stop ECLK, reset, release, pause, DLL update, release pause.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :DQS_LI_DEL_VAL, default: 0
  param :DQS_LI_DEL_ADJ, default: "PLUS"
  param :DQS_LO_DEL_VAL, default: 0
  param :DQS_LO_DEL_ADJ, default: "PLUS"
  param :GSR, default: "DISABLED"

  input :dqsi, 1
  input :read1, 1
  input :read0, 1
  input :readclksel2, 1
  input :readclksel1, 1
  input :readclksel0, 1
  input :ddrdel, 1
  input :eclk, 1
  input :sclk, 1
  input :rst, 1
  input :dyndelay7, 1
  input :dyndelay6, 1
  input :dyndelay5, 1
  input :dyndelay4, 1
  input :dyndelay3, 1
  input :dyndelay2, 1
  input :dyndelay1, 1
  input :dyndelay0, 1
  input :pause, 1
  input :rdloadn, 1
  input :rdmove, 1
  input :rddirection, 1
  input :wrloadn, 1
  input :wrmove, 1
  input :wrdirection, 1
  output :dqsr90, 1
  output :dqsw, 1
  output :dqsw270, 1
  output :rdpntr2, 1
  output :rdpntr1, 1
  output :rdpntr0, 1
  output :wrpntr2, 1
  output :wrpntr1, 1
  output :wrpntr0, 1
  output :datavalid, 1
  output :burstdet, 1
  output :rdcflag, 1
  output :wrcflag, 1

  blackbox :dqsbufm, "DQSBUFM",
    params: [
      DQS_LI_DEL_VAL: :DQS_LI_DEL_VAL,
      DQS_LI_DEL_ADJ: :DQS_LI_DEL_ADJ,
      DQS_LO_DEL_VAL: :DQS_LO_DEL_VAL,
      DQS_LO_DEL_ADJ: :DQS_LO_DEL_ADJ,
      GSR: :GSR
    ],
    ports: [
      DQSI: :dqsi,
      READ1: :read1,
      READ0: :read0,
      READCLKSEL2: :readclksel2,
      READCLKSEL1: :readclksel1,
      READCLKSEL0: :readclksel0,
      DDRDEL: :ddrdel,
      ECLK: :eclk,
      SCLK: :sclk,
      RST: :rst,
      DYNDELAY7: :dyndelay7,
      DYNDELAY6: :dyndelay6,
      DYNDELAY5: :dyndelay5,
      DYNDELAY4: :dyndelay4,
      DYNDELAY3: :dyndelay3,
      DYNDELAY2: :dyndelay2,
      DYNDELAY1: :dyndelay1,
      DYNDELAY0: :dyndelay0,
      PAUSE: :pause,
      RDLOADN: :rdloadn,
      RDMOVE: :rdmove,
      RDDIRECTION: :rddirection,
      WRLOADN: :wrloadn,
      WRMOVE: :wrmove,
      WRDIRECTION: :wrdirection,
      DQSR90: :dqsr90,
      DQSW: :dqsw,
      DQSW270: :dqsw270,
      RDPNTR2: :rdpntr2,
      RDPNTR1: :rdpntr1,
      RDPNTR0: :rdpntr0,
      WRPNTR2: :wrpntr2,
      WRPNTR1: :wrpntr1,
      WRPNTR0: :wrpntr0,
      DATAVALID: :datavalid,
      BURSTDET: :burstdet,
      RDCFLAG: :rdcflag,
      WRCFLAG: :wrcflag
    ]
end
