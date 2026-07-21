defmodule Hw.Interface.USBEndpointIn do
  @moduledoc """
  USB endpoint IN interface — endpoint buffer from upper layer (CDC) to SIE.

  The upper layer (CDC) loads data into the SIE's IN buffer. The SIE
  responds to host IN tokens autonomously — sending data if the buffer
  is loaded, or NAK if it is not.

  ## Protocol

  ### Loading a data packet (e.g. descriptor response, bulk IN):

  1. CDC sets `ep`, `pid` (DATA0 or DATA1), presents first byte on `data`,
     asserts `valid`, then asserts `loaded`.
  2. SIE asserts `ready` each time it consumes a byte. CDC advances `data`
     on the next cycle after `ready`.
  3. CDC deasserts `valid` when there are no more bytes (end of packet).
  4. SIE waits for the next IN token for this `ep`, then transmits the
     buffered bytes, appends CRC, drives EOP.
  5. If the host ACKs, SIE pulses `done` and clears its internal
     `ep_loaded` flag. CDC may then load the next packet.
  6. If the host NAKs or the ACK is lost, SIE retransmits on the next
     IN token automatically (data is still buffered).

  ### Loading a zero-length packet (e.g. STATUS IN for SET_ADDRESS):

  1. CDC sets `ep` and `pid`, asserts `loaded`, keeps `valid` deasserted.
  2. SIE responds to next IN token with zero-length DATAx + CRC.
  3. SIE pulses `done` on host ACK.

  ### NAK behaviour:

  When the host sends an IN token for an endpoint whose buffer is not
  loaded, the SIE sends NAK and pulses `nak` to inform CDC. CDC can use
  this to implement flow control if desired, but may also ignore it.

  ### SETUP abort:

  When the SIE receives a SETUP token for EP0, it automatically clears
  the EP0 IN buffer (deasserts internal `ep0_loaded`). CDC should detect
  this via the `USBEndpointOut` interface and re-arm as appropriate.
  The SIE asserts `nak` on any pending EP0 IN to signal the abort.

  ## Signal directions

  Signals marked `:cdc_drives` are outputs from CDC, inputs to SIE.
  Signals marked `:sie_drives` are outputs from SIE, inputs to CDC.
  """

  use Hw.Interface

  # CDC → SIE: describe and supply the buffer
  signal :ep,     4, :cdc_drives   # which endpoint IN buffer to load
  signal :pid,    8, :cdc_drives   # DATA0 (0xC3) or DATA1 (0x4B)
  signal :data,   8, :cdc_drives   # next byte to send
  signal :valid,  1, :cdc_drives   # data byte is valid (deassert = end of packet)
  signal :loaded, 1, :cdc_drives   # buffer is loaded; ACK IN tokens for this ep

  # SIE → CDC: flow control and completion
  signal :ready,  1, :sie_drives   # SIE consumed the current byte; advance data
  signal :done,   1, :sie_drives   # packet sent and host ACKed (one-cycle pulse)
  signal :nak,    1, :sie_drives   # IN token arrived with no buffer (or SETUP abort)
end
