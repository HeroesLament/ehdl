defmodule Hw.Xilinx.BUFG do
  @moduledoc """
  Xilinx 7-series global clock buffer.

  A clock coming out of the PS (`FCLKCLK[n]`) or off a pin must be driven onto
  a global clock tree before it can clock fabric logic. Skipping the buffer
  either fails to route or produces a design whose "clock" is an ordinary
  signal on local routing — which is the kind of fault that looks like random
  logic corruption rather than a clocking problem.

  GenZ's working AXI example routes `FCLKCLK` through an explicit `BUFG` for
  this reason, and so should any design here.

      instance :clkbuf, Hw.Xilinx.BUFG, i: :fclk_clk0, o: :axi_clk
  """

  use Hw.Component

  input :i, 1
  output :o, 1

  blackbox :bufg, "BUFG",
    ports: [
      I: :i,
      O: :o
    ]
end
