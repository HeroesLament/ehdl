defmodule Hw.UART.RX do
  @moduledoc """
  8N1 UART receiver.

  Samples RXD at mid-bit using 1x baud clock derived from CLK_FREQ/BAUD_RATE.
  Mealy-style `valid` output — goes high the same cycle the stop bit is confirmed.
  Holds `valid` high until `ready` is asserted by the consumer.

  ## Parameters

  - `CLK_FREQ`  - Clock frequency in Hz (default: 48_000_000)
  - `BAUD_RATE` - Baud rate (default: 115_200)

  ## Ports

  - `clk`   - Clock
  - `rst`   - Synchronous reset, active high
  - `rxd`   - Serial input, idle high
  - `data`  - Received byte (stable while valid is high)
  - `valid` - High when a byte is ready; held until ready asserted
  - `ready` - Assert to acknowledge the current byte and arm for next

  ## Sampling

  On falling edge of RXD (start bit), waits half a baud period to hit the
  mid-point of the start bit, then samples every full baud period for 8 bits.
  After sampling the stop bit, latches data and asserts valid.

  At 48 MHz / 115200 baud: 416 clocks/bit, 208 clocks to mid-start.

  ## FSM states

  - `:idle`  — waiting for start bit (RXD falling edge)
  - `:start` — counting to mid-start-bit (half baud period)
  - `:data`  — shifting in 8 data bits, one per full baud period
  - `:stop`  — waiting for stop bit, then latching and asserting valid
  """

  use Hw.Component

  param :CLK_FREQ,  default: 48_000_000
  param :BAUD_RATE, default: 115_200

  clock :clk, freq: 48.0
  input  :rst,   1
  input  :rxd,   1
  input  :ready, 1
  output :data,  8
  output :valid, 1

  wire :baud_cnt,  20, init: 0
  wire :bit_cnt,    3, init: 0
  wire :shift_reg,  8, init: 0
  wire :data_reg,   8, init: 0
  wire :valid_reg,  1, init: 0
  wire :full_tick,  1
  wire :half_tick,  1

  comb do
    full_tick = (baud_cnt == CLK_FREQ / BAUD_RATE - 1)
    half_tick = (baud_cnt == CLK_FREQ / BAUD_RATE / 2 - 1)
    data  = data_reg
    valid = valid_reg
  end

  # Clear valid when the consumer acknowledges.
  # Used in every FSM state where a byte may be held pending acknowledgement.
  defhw ack_if_ready() do
    if valid_reg and ready do
      valid_reg = 0
    end
  end

  # Latch the shift register into data_reg and assert valid.
  # Used by the FSM on stop-bit confirmation.
  defhw latch_byte() do
    data_reg  = shift_reg
    valid_reg = 1
    baud_cnt  = 0
    bit_cnt   = 0
  end

  # Sample one data bit into the shift register.
  # Used by the FSM on each full baud tick during data reception.
  defhw sample_bit() do
    shift_reg = {rxd, shift_reg[7..1]}
    baud_cnt  = 0
  end

  fsm :rx_state, clock: :clk, reset: :rst, init: :idle do
    defaults do
      baud_cnt = baud_cnt + 1
    end

    case rx_state do
      :idle ->
        baud_cnt = 0
        ack_if_ready()
        on rxd == 0, next: :start

      :start ->
        ack_if_ready()
        on half_tick do
          baud_cnt = 0
          bit_cnt  = 0
          next :data
        end

      :data ->
        ack_if_ready()
        on full_tick do
          sample_bit()
          on bit_cnt == 7, next: :stop
          on :else do
            bit_cnt = bit_cnt + 1
          end
        end

      :stop ->
        on full_tick do
          latch_byte()
          next :idle
        end
    end
  end

  @doc "Simulation interface: wait for a byte to be received, acknowledge it, and return the value."
  def recv(sim, opts \\ []) do
    Hw.Sim.apply_defhw(sim, __MODULE__, :_recv, [], opts)
  end

  defhw _recv() do
    on valid == 1 do
      ready = 1
    end
    on valid == 0 do
      ready = 0
    end
  end
end
