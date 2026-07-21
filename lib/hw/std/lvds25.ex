defmodule Hw.LVDS25Input do
  @moduledoc """
  ECP5 LVDS25 differential input buffer.

  Reads a differential signal pair and outputs a single logic bit:
  high when the positive input (A) is greater than the negative (AN).

  ## Usage on ULX3S

  The dedicated USB differential input pins E16/F16 are connected to
  `usb_fpga_dp` and `usb_fpga_dn` respectively. These feed directly
  into this primitive without going through the bidirectional output
  driver path, giving a clean noise-rejected differential read.

  LPF constraints for these pins:

      LOCATE COMP "usb_fpga_dp" SITE "E16";
      LOCATE COMP "usb_fpga_dn" SITE "F16";
      IOBUF  PORT "usb_fpga_dp" PULLMODE=NONE IO_TYPE=LVDS25;
      IOBUF  PORT "usb_fpga_dn" PULLMODE=NONE IO_TYPE=LVDS25;

  ## Example

      wire :dp_diff, 1

      instance :lvds_rx, ECP5.LVDS25Input,
        a:  :usb_fpga_dp,
        an: :usb_fpga_dn,
        z:  :dp_diff
  """

  use Hw.Component

  input  :a,  1   # positive differential input
  input  :an, 1   # negative differential input
  output :z,  1   # output: 1 when a > an, 0 when a < an

  blackbox :buf, "LVDS25",
    params: [],
    ports: [
      A:  :a,
      AN: :an,
      Z:  :z
    ]
end
