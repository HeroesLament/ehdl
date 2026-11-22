defmodule Hw.ECP5.ILVDS do
  @moduledoc """
  ECP5 differential input buffer: `z` is 1 when `a` > `an`.

  The pair is one PIO pair (A on the true pin, AN on its complement); the IO
  standard comes from the `.lpf`, not from the primitive:

      LOCATE COMP "usb_fpga_dp" SITE "E16";
      IOBUF  PORT "usb_fpga_dp" IO_TYPE=LVDS;

  Only the true-pin port needs constraining; the complement is implied. The
  ECP5 GPIO banks are 3.3 V, so a differential *input* works on any pair but
  true LVDS *output* (`Hw.ECP5.OLVDS`) needs a bank powered at 2.5 V.

  On the ULX3S the USB pins E16 / F16 (`usb_fpga_dp` / `usb_fpga_dn`) are a
  pair; reading them through this primitive gives a noise-rejected
  differential receive beside the single-ended drive path.

      instance :usb_rx, Hw.ECP5.ILVDS, a: :usb_fpga_dp, an: :usb_fpga_dn, z: :dp_diff

  Replaces `Hw.LVDS25Input`, whose blackbox named a module `LVDS25`. No ECP5
  primitive has that name (yosys's ECP5 cell library has `ILVDS`, with the
  same A / AN / Z ports), so it could not have built.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  input :a, 1
  input :an, 1
  output :z, 1

  blackbox :ilvds, "ILVDS", ports: [A: :a, AN: :an, Z: :z]
end
