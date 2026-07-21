defmodule Hw.Interface.USBEndpointOut do
  @moduledoc """
  USB endpoint OUT interface — byte stream from SIE to upper layer (CDC).

  The SIE drives all signals. The upper layer is purely a consumer.

  ## Protocol

  For each OUT or SETUP transaction the SIE receives from the host:

  1. SIE asserts `valid` for each payload byte, with `ep` and `setup`
     stable for the entire packet.
  2. On the last byte, SIE asserts `pkt_end` on the same cycle as `valid`
     (or alone if the packet was zero-length, though zero-length OUT is rare).
  3. `pkt_end` is only asserted if the packet CRC was good. Corrupt packets
     are silently dropped — the upper layer never sees them.
  4. `setup` is asserted for SETUP transactions, deasserted for OUT.
     The SIE always ACKs SETUP automatically; the upper layer has no choice.

  ## Notes

  - The SIE filters by device address internally. The upper layer only sees
    packets addressed to this device.
  - Toggle checking (DATA0/DATA1 sequence) is the upper layer's responsibility
    if it cares (CDC-ACM generally doesn't for EP0).
  - `ep` is stable from first `valid` through `pkt_end`.
  """

  use Hw.Interface

  # All signals driven by the SIE (provider role)
  signal :data,    8, :provider_drives   # payload byte
  signal :valid,   1, :provider_drives   # payload byte is valid this cycle
  signal :ep,      4, :provider_drives   # endpoint number (stable for packet)
  signal :setup,   1, :provider_drives   # this is a SETUP transaction, not OUT
  signal :pkt_end, 1, :provider_drives   # last byte of packet, CRC verified
end
