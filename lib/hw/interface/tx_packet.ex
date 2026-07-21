defmodule Hw.Interface.TxPacket do
  @moduledoc """
  TX packet handshake interface between a packet consumer (CDC) and
  a packet provider (SIE).

  ## Protocol

  The consumer initiates a packet transfer by asserting `pkt_req` and
  holding it high until the provider acknowledges with a one-cycle
  `pkt_ack` pulse. At that point the provider has latched `pkt_pid`
  and begins transmitting SYNC + PID onto the wire.

  For packets with a data payload, the provider asserts `byte_ready`
  each time it needs the next byte. The consumer responds by placing
  the byte on `byte_data` and asserting `byte_valid`. This continues
  until the consumer deasserts `byte_valid` to signal end of payload,
  at which point the provider appends CRC and EOP.

  For zero-length packets (STATUS IN), the consumer asserts `pkt_req`
  with `byte_valid` deasserted from the start.

  The provider asserts `pkt_done` for one cycle when the EOP has been
  driven and the bus is released.

  ## Timing diagram (zero-length STATUS IN)

      clk        __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
      pkt_req    ___|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|___
      pkt_ack    _________|‾|_____________________
      pkt_pid    ---XXXXX[PID]-------------------
      byte_valid ____________________________________  (never asserted)
      byte_ready ____________________________________  (never asserted)
      pkt_done   ________________________________|‾|_

  ## Timing diagram (data IN)

      clk        __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
      pkt_req    ___|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|__
      pkt_ack    _________|‾|____________________
      byte_ready _____________|‾|___|‾|__________
      byte_valid _____________|‾|___|‾|__________
      byte_data  -----------[B0]---[B1]-----------
      pkt_done   __________________________|‾|___
  """

  use Hw.Interface

  # consumer_drives: CDC (consumer) drives this signal → SIE (provider) reads it
  # provider_drives: SIE (provider) drives this signal → CDC (consumer) reads it

  signal :pkt_req,    1, :consumer_drives   # request to start a packet
  signal :pkt_ack,    1, :provider_drives   # provider has latched the request
  signal :pkt_pid,    8, :consumer_drives   # PID byte to transmit
  signal :byte_data,  8, :consumer_drives   # next payload byte
  signal :byte_valid, 1, :consumer_drives   # payload byte is valid
  signal :byte_ready, 1, :provider_drives   # provider ready for next byte
  signal :pkt_done,   1, :provider_drives   # packet transmission complete
end
