defmodule Hw.ESP32.ProgCtrl do
  @moduledoc """
  ESP32 programming control via esptool auto-reset protocol.

  Translates CDC-ACM DTR/RTS line state into ESP32 EN and GPIO0 signals.

    RTS=1, DTR=0  →  assert reset (EN low for RESET_HOLD_US, then release)
    RTS=1, DTR=1  →  reset into bootloader (EN low, GPIO0 low, then EN high)
    RTS=0, DTR=x  →  normal operation (EN high, GPIO0 high)

  ## Parameters

  - `CLK_FREQ`      - Clock frequency in Hz (default: 48_000_000)
  - `RESET_HOLD_US` - Reset pulse width in microseconds (default: 100)
  """

  use Hw.Component

  param :CLK_FREQ,      default: 48_000_000
  param :RESET_HOLD_US, default: 100

  clock :clk
  input  :rst,       1
  input  :dtr,       1
  input  :rts,       1
  output :esp_en,    1
  output :esp_gpio0, 1

  # States: idle(0) asserting(1) releasing(2)
  wire :state,   2, init: 0
  wire :counter, 20, init: 0

  wire :zero,  1
  wire :one,   1
  wire :w2_0,  2
  wire :w2_1,  2
  wire :w2_2,  2
  wire :counter_next, 20
  wire :hold_done,    1
  wire :boot_mode,    1   # DTR high = enter bootloader on release

  comb do
    zero  = 0
    one   = 1
    w2_0  = 0
    w2_1  = 1
    w2_2  = 2

    counter_next = counter + 1
    hold_done    = (counter == CLK_FREQ / 1_000_000 * RESET_HOLD_US - 1)
    boot_mode    = dtr

    esp_en    = bnot(state == w2_1)   # EN low only during assert state
    esp_gpio0 = bnot(state == w2_1 and boot_mode)
  end

  on :clk do
    if rst do
      state   = w2_0
      counter = 0
    else
      case state do
        0 ->
          if rts do
            state   = w2_1
            counter = 0
          end
        1 ->
          if hold_done do
            state   = w2_2
            counter = 0
          else
            counter = counter_next
          end
        2 ->
          # Hold released state briefly then return to idle
          if hold_done do
            state   = w2_0
            counter = 0
          else
            counter = counter_next
          end
      end
    end
  end
end
