defmodule Hw.CAN.Controller do
  @moduledoc """
  CAN 2.0A protocol controller — bit engine, frame walk, arbitration and fault
  confinement. Drives a bare transceiver (SN65HVD230, TJA1051, ...) directly;
  no MCP2515, no SPI.

  Instantiates `Hw.CAN.BitTiming` for time quanta and `Hw.CAN.CRC15` for the
  frame check. One instance per CAN channel; instantiate several to run
  independent buses from one device.

  > #### Not signed off on silicon {: .warning}
  >
  > Everything here is verified only at elaboration level. Per project rule, no
  > correctness claim about hardware behaviour is made until this has been
  > flashed and observed against an independent witness. See "Bring-up oracle".

  ## Scope

  Implemented: standard 11-bit data frames, transmit and receive; bit stuffing
  and destuffing; CRC-15 generation and checking; arbitration by
  transmit-and-monitor with automatic reversion to receiver; ACK generation and
  detection; bit, stuff, form, CRC and ACK error detection; error flags; TEC and
  REC counters with error-active, error-passive and bus-off states.

  Deliberately deferred, and detected rather than mishandled:

    * **Extended 29-bit frames.** A received frame with IDE recessive is
      recognised and discarded cleanly rather than mis-parsed, and `rx_ext`
      pulses so a consumer knows it happened. Transmission is 11-bit only.
    * **Remote frames.** RTR recessive is flagged on `rx_rtr`; the data field is
      correctly treated as absent.
    * **Overload frames.** Never generated. Received overload flags are absorbed
      by the error-frame handling path.
    * **Bus-off recovery.** Entry to bus-off is implemented and latched;
      automatic recovery after 128 x 11 recessive bits is not. Recovery is a
      deliberate policy decision on a motion controller — coming back silently
      after a wiring fault is usually the wrong behaviour — so it is left to the
      supervisor via `reset`.

  ## Ports

  ### Bus
  - `rx` — from the transceiver's R pin. Synchronised internally, 2 FF.
  - `tx` — to the transceiver's D pin. 0 dominant, 1 recessive. Idles recessive.

  ### Transmit
  - `tx_id` (11), `tx_dlc` (4), `tx_data` (64) — frame to send, MSB-first byte
    order in `tx_data` (byte 0 is bits 63..56)
  - `tx_req` — hold high to request transmission; sampled at bus idle
  - `tx_busy` — high from the moment the frame is accepted until it completes
  - `tx_done` — one-cycle pulse when a frame is transmitted and acknowledged
  - `tx_lost` — one-cycle pulse when arbitration was lost; the frame was not
    sent and the request should be re-presented

  ### Receive
  - `rx_id` (11), `rx_dlc` (4), `rx_data` (64) — last accepted frame
  - `rx_valid` — one-cycle pulse when a frame passed CRC and was acknowledged
  - `rx_rtr`, `rx_ext` — one-cycle pulses for frame kinds this core does not
    deliver

  ### Fault confinement
  - `tec` (9), `rec` (9) — transmit and receive error counters
  - `err_passive` — TEC or REC has exceeded 127
  - `bus_off` — TEC has exceeded 255; the core has stopped driving the bus
  - `err_pulse` — one-cycle pulse on each detected error, for diagnostics

  ## Bring-up oracle (silicon, no simulation sign-off)

  1. Transmit from fabric with the MCP2515 path **and** a CANable on the PC both
     receiving. Two independent witnesses sharing no silicon with this core.
  2. Reverse: MCP2515 transmits, this core receives. First exercise of the RX
     direction anywhere in the project.
  3. Alone on a terminated bus with no other node: no ACK arrives, so TEC must
     climb by 8 per attempt and the core must reach error-passive at 128 and
     bus-off at 256. Timing that climb is the cheapest proof the fault
     confinement logic is real rather than merely present.
  """

  use Hw.CAN.ControllerTemplate, bitrate: 1_000_000, clk_freq: 48_000_000
end
