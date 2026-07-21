defmodule Hw.UART.TX do
  @moduledoc """
  8N1 UART transmitter.

  Serializes bytes to a UART TX line at a configurable baud rate.
  Valid/ready handshake on input. Combinational `txd` and `ready` outputs.

  ## Parameters

  - `CLK_FREQ`  - Clock frequency in Hz (default: 48_000_000)
  - `BAUD_RATE` - Baud rate (default: 115_200)

  ## Ports

  - `clk`   - Clock
  - `rst`   - Synchronous reset, active high
  - `data`  - Byte to transmit
  - `valid` - Assert with `data` stable to begin transmission
  - `ready` - High when idle and accepting new data
  - `txd`   - Serial output, idle high

  ## FSM states

  - `:idle`    — ready, waiting for valid
  - `:sending` — shifting out 10-bit frame (start + 8 data + stop)
  """

  use Hw.Component

  param :CLK_FREQ,  default: 48_000_000
  param :BAUD_RATE, default: 115_200

  clock :clk, freq: 48.0
  input  :rst,   1
  input  :data,  8
  input  :valid, 1
  output :ready, 1
  output :txd,   1

  wire :baud_cnt,  20, init: 0
  wire :bit_cnt,    4, init: 0
  wire :shift_reg, 10, init: 0b1111111111
  wire :start_bit,  1
  wire :stop_bit,   1
  wire :tick,       1

  comb do
    start_bit = 0
    stop_bit  = 1
    tick      = (baud_cnt == CLK_FREQ / BAUD_RATE - 1)
    txd       = shift_reg[0..0]
  end

  # Load a byte into the shift register as a complete 8N1 frame.
  # Used by the FSM on transition from idle→sending, and by the
  # simulation interface to inject a frame directly.
  defhw load_frame(frame_byte) do
    shift_reg = {stop_bit, frame_byte, start_bit}
    bit_cnt   = 0
    baud_cnt  = 0
  end

  # Shift out one bit: right-shift the frame, insert idle level at MSB.
  # Used by the FSM on each baud tick during sending.
  defhw shift_bit() do
    shift_reg = {stop_bit, shift_reg[9..1]}
    baud_cnt  = 0
    bit_cnt   = bit_cnt + 1
  end

  fsm :tx_state, clock: :clk, reset: :rst, init: :idle do
    defaults do
      ready = 1
    end

    case tx_state do
      :idle ->
        ready = 1
        on valid do
          load_frame(data)
          next :sending
        end

      :sending ->
        ready    = 0
        baud_cnt = baud_cnt + 1
        on tick do
          shift_bit()
          on bit_cnt == 9, next: :idle
        end
    end
  end

  @doc "Simulation interface: drive valid/data and wait for the full frame to transmit."
  def send(sim, byte, opts \\ []) do
    Hw.Sim.apply_defhw(sim, __MODULE__, :_send, [byte], opts)
  end

  defhw _send(tx_byte) do
    valid = 1
    data  = tx_byte
    on tx_state == 1 do   # wait for FSM to latch the byte and start sending
    end
    on tx_state == 0 do   # wait for the full 10-bit frame to complete
    end
  end
end
