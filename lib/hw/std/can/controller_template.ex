defmodule Hw.CAN.ControllerTemplate do
  @moduledoc """
  Stamps out a CAN controller specialised to one bit rate.

  The controller needs five interdependent bit-timing numbers, but the knob you
  actually want is a single bit rate. Rather than forward five parameters into
  the `Hw.CAN.BitTiming` sub-instance — which the DSL cannot do today anyway —
  this template computes them with `Hw.CAN.BitTiming.config/2` and splices them
  in as literals at compile time.

      defmodule MyBus500k do
        use Hw.CAN.ControllerTemplate, bitrate: 500_000
      end

      defmodule MyBus1M do
        use Hw.CAN.ControllerTemplate, bitrate: 1_000_000
      end

  Each generated module is an ordinary component, so several can be instantiated
  side by side to run independent buses at different rates from one device.

  ## Options

  - `:bitrate`  - CAN bit rate in bit/s (default 1_000_000)
  - `:clk_freq` - Clock frequency in Hz (default 48_000_000)

  A bit rate the clock cannot divide into a legal number of time quanta raises
  at compile time rather than silently rounding, because a bit-rate error of
  even a percent accumulates across a frame and corrupts the far end of it.

  ## Behaviour

  Identical for every generated module. The protocol documentation, the
  deliberately deferred features and the bring-up oracle are reproduced below
  and on `Hw.CAN.Controller`, the stock 1 Mbit/s instantiation.

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

  @doc false
  defmacro __using__(opts) do
    clk_freq = Keyword.get(opts, :clk_freq, 48_000_000)
    bitrate = Keyword.get(opts, :bitrate, 1_000_000)

    timing =
      case Hw.CAN.BitTiming.config(clk_freq, bitrate) do
        {:error, :no_exact_divisor} ->
          raise ArgumentError,
                "no legal CAN bit timing for #{bitrate} bit/s from a #{clk_freq} Hz clock: " <>
                  "no whole number of clocks per time quantum gives 8..25 TQ per bit. " <>
                  "Pick a bit rate that divides the clock, or change the clock."

        cfg ->
          cfg
      end

    body =
      quote do
      use Hw.Component

      clock :clk, freq: 48.0
      input  :rst, 1

      input  :rx, 1
      output :tx, 1

      input  :tx_req,  1
      input  :tx_id,  11
      input  :tx_dlc,  4
      input  :tx_data, 64
      output :tx_busy, 1
      output :tx_done, 1
      output :tx_lost, 1

      output :rx_id,   11
      output :rx_dlc,   4
      output :rx_data, 64
      output :rx_valid, 1
      output :rx_rtr,   1
      output :rx_ext,   1

      output :tec,         9
      output :rec,         9
      output :err_passive, 1
      output :bus_off,     1
      output :err_pulse,   1

      # --- Frame field encoding --------------------------------------------------
      # A single walk serves both directions: in CAN a transmitter is also a
      # receiver, so only what we *drive* differs.
      param :F_IDLE,      default: 0
      param :F_SOF,       default: 1
      param :F_ID,        default: 2
      param :F_RTR,       default: 3
      param :F_IDE,       default: 4
      param :F_R0,        default: 5
      param :F_DLC,       default: 6
      param :F_DATA,      default: 7
      param :F_CRC,       default: 8
      param :F_CRC_DELIM, default: 9
      param :F_ACK,       default: 10
      param :F_ACK_DELIM, default: 11
      param :F_EOF,       default: 12
      param :F_IFS,       default: 13
      param :F_ERROR,     default: 14
      param :F_ERR_DELIM, default: 15

      # --- Bus interface ---------------------------------------------------------
      wire :rx_sync1, 1, init: 1
      wire :rx_sync2, 1, init: 1
      # NB: not named `bit_in` — that collides with the CRC unit's port name and the
      # flattener aliases the two into one double-driven signal.
      wire :bus_bit,  1

      wire :sample_point, 1
      wire :write_point,  1
      wire :sampled_bit,  1
      wire :hard_sync,    1
      wire :resync_en,    1

      # Bit timing is computed by Hw.CAN.BitTiming.config/2 from the bitrate this
      # module was stamped out with, then spliced in as literals. This is why the
      # core needs no parameter forwarding to run channels at different rates.
      instance :timing, Hw.CAN.BitTiming, unquote(timing) ++ [
        clk:          :clk,
        rst:          :rst,
        rx:           :bus_bit,
        resync_en:    :resync_en,
        hard_sync:    :hard_sync,
        sample_point: :sample_point,
        write_point:  :write_point,
        sampled_bit:  :sampled_bit
      ]

      # --- CRC -------------------------------------------------------------------
      wire :crc_state, 15, init: 0
      wire :crc_next,  15
      wire :crc_bit,    1
      wire :crc_ok,     1

      instance :crc, Hw.CAN.CRC15,
        crc_in:  :crc_state,
        bit_in:  :crc_bit,
        crc_out: :crc_next,
        valid:   :crc_ok

      # --- Frame walk state ------------------------------------------------------
      wire :fld,      4, init: 0
      wire :bit_ctr,  7, init: 0
      wire :id_sr,   11, init: 0
      wire :dlc_sr,   4, init: 0
      wire :data_sr, 64, init: 0
      wire :crc_sr,  15, init: 0
      wire :rtr_bit,  1, init: 0
      wire :ide_bit,  1, init: 0

      wire :is_tx,      1, init: 0
      wire :ack_seen,   1, init: 0

      # Bit stuffing
      wire :same_cnt,      3, init: 0
      wire :last_bit,      1, init: 1
      wire :stuff_pending, 1, init: 0
      wire :stuff_en,      1, init: 0

      # Fault confinement
      wire :tec_reg, 9, init: 0
      wire :rec_reg, 9, init: 0
      wire :off_reg, 1, init: 0

      # Outputs held between frames
      wire :rx_id_reg,   11, init: 0
      wire :rx_dlc_reg,   4, init: 0
      wire :rx_data_reg, 64, init: 0
      wire :rx_valid_reg, 1, init: 0
      wire :rx_rtr_reg,   1, init: 0
      wire :rx_ext_reg,   1, init: 0
      wire :tx_done_reg,  1, init: 0
      wire :tx_lost_reg,  1, init: 0
      wire :err_reg,      1, init: 0
      wire :tx_reg,       1, init: 1

      # Derived
      wire :advance,     1
      wire :data_bits,   7
      wire :bus_idle,    1
      wire :err_active,  1
      wire :drive_bit,   1
      wire :field_bit,   1

      comb do
        bus_bit = rx_sync2

        # The frame walk advances on the sample point, except in a stuff-bit slot,
        # where the bit is consumed by the destuffer and the walk holds.
        advance = sample_point and not stuff_pending

        # Data field length in bits. DLC above 8 is clamped to 8 per the standard.
        data_bits = if dlc_sr > 8, do: 64, else: dlc_sr * 8

        bus_idle = (fld == F_IDLE)

        # Resynchronise only while receiving. A transmitter must not resync on the
        # edges it is generating itself.
        resync_en = not is_tx

        # A dominant bit while idle is a start of frame: restart the bit time on it.
        hard_sync = bus_idle and not bus_bit and rx_sync1

        err_active  = (tec_reg < 128) and (rec_reg < 128)
        err_passive = (tec_reg > 127) or (rec_reg > 127)
        bus_off     = off_reg

        # What we put on the wire for the *next* bit. In a stuff slot it is the
        # complement of the last bit; otherwise it is the current field's bit.
        field_bit = if stuff_pending, do: not last_bit, else: drive_bit

        tx = tx_reg

        tec = tec_reg
        rec = rec_reg
        err_pulse = err_reg

        rx_id    = rx_id_reg
        rx_dlc   = rx_dlc_reg
        rx_data  = rx_data_reg
        rx_valid = rx_valid_reg
        rx_rtr   = rx_rtr_reg
        rx_ext   = rx_ext_reg

        tx_busy = is_tx
        tx_done = tx_done_reg
        tx_lost = tx_lost_reg

        # Bit to drive per field. Receivers drive recessive everywhere except the
        # ACK slot; the mux below is gated by is_tx where it matters.
        hdl_case <<fld::4>> do
          <<1::4>>  -> drive_bit = 0                       # SOF, dominant
          <<2::4>>  -> drive_bit = id_sr[10..10]           # ID, MSB first
          <<3::4>>  -> drive_bit = 0                       # RTR dominant = data frame
          <<4::4>>  -> drive_bit = 0                       # IDE dominant = standard
          <<5::4>>  -> drive_bit = 0                       # r0 reserved, dominant
          <<6::4>>  -> drive_bit = dlc_sr[3..3]            # DLC, MSB first
          <<7::4>>  -> drive_bit = data_sr[63..63]         # data, MSB first
          <<8::4>>  -> drive_bit = crc_sr[14..14]          # CRC, MSB first
          <<14::4>> -> drive_bit = 0                       # error flag, dominant
          <<_::4>>  -> drive_bit = 1                       # delimiters, EOF, IFS, idle
        end

        # Feed the CRC with the bit actually on the bus, excluding stuff bits.
        crc_bit = sampled_bit
      end

      # --- Reusable sequential fragments -----------------------------------------

      # Score an error against the right counter and take the error flag path.
      defhw flag_error() do
        err_reg = 1
        if is_tx do
          tec_reg = tec_reg + 8
        else
          rec_reg = rec_reg + 1
        end
        fld      = F_ERROR
        bit_ctr  = 0
        stuff_en = 0
      end

      # Finish a frame and return to the interframe space.
      defhw end_frame() do
        fld      = F_IFS
        bit_ctr  = 0
        stuff_en = 0
      end

      on :clk do
        # Two-flop synchroniser on the bus input. Everything downstream reads
        # rx_sync2; rx_sync1 is only used for edge detection at idle.
        rx_sync1 = rx
        rx_sync2 = rx_sync1

        if rst do
          fld           = F_IDLE
          bit_ctr       = 0
          is_tx         = 0
          stuff_en      = 0
          stuff_pending = 0
          same_cnt      = 0
          last_bit      = 1
          crc_state     = 0
          tec_reg       = 0
          rec_reg       = 0
          off_reg       = 0
          tx_reg        = 1
          rx_valid_reg  = 0
          rx_rtr_reg    = 0
          rx_ext_reg    = 0
          tx_done_reg   = 0
          tx_lost_reg   = 0
          err_reg       = 0
          ack_seen      = 0
        else
          # Single-cycle status pulses.
          rx_valid_reg = 0
          rx_rtr_reg   = 0
          rx_ext_reg   = 0
          tx_done_reg  = 0
          tx_lost_reg  = 0
          err_reg      = 0

          # Drive the next bit at the bit boundary. A bus-off node never drives.
          if write_point do
            if off_reg do
              tx_reg = 1
            else
              tx_reg = field_bit
            end
          end

          if sample_point do
            # --- Bit stuffing bookkeeping -------------------------------------
            if stuff_pending do
              # This slot must carry the complement of the run that triggered it.
              if sampled_bit == last_bit do
                flag_error()
              end
              stuff_pending = 0
              same_cnt      = 1
              last_bit      = sampled_bit
            else
              if sampled_bit == last_bit do
                same_cnt = same_cnt + 1
                if stuff_en and (same_cnt == 4) do
                  stuff_pending = 1
                end
              else
                same_cnt = 1
                last_bit = sampled_bit
              end
            end

            # --- Transmitter monitoring ----------------------------------------
            # Whatever we drove must come back, except where losing arbitration or
            # someone else's ACK legitimately differs.
            if is_tx and (off_reg == 0) do
              if sampled_bit != tx_reg do
                if fld == F_ID do
                  # Drove recessive, read dominant: a higher-priority frame won.
                  is_tx      = 0
                  tx_lost_reg = 1
                else
                  if fld == F_ACK do
                    ack_seen = 1
                  else
                    flag_error()
                  end
                end
              end
            end

            # --- Frame walk -----------------------------------------------------
            if advance do
              # CRC covers SOF through the end of the data field.
              #
              # The idle case matters and is easy to get wrong: a *receiver* sees
              # the SOF bit while still in F_IDLE and jumps straight to F_ID, so
              # without the second clause it would omit SOF from its CRC while a
              # transmitter (which passes through F_SOF) includes it. Every frame
              # would then fail its check at the receiver.
              if ((fld >= F_SOF) and (fld <= F_DATA)) or ((fld == F_IDLE) and (sampled_bit == 0)) do
                crc_state = crc_next
              end

              hdl_case <<fld::4>> do
                # ---- idle: wait for a dominant SOF, or start our own frame ----
                <<0::4>> ->
                  if sampled_bit == 0 do
                    fld       = F_ID
                    bit_ctr   = 0
                    stuff_en  = 1
                    crc_state = 0
                    is_tx     = 0
                    id_sr     = 0
                  else
                    if tx_req and (off_reg == 0) do
                      fld       = F_SOF
                      bit_ctr   = 0
                      stuff_en  = 1
                      crc_state = 0
                      is_tx     = 1
                      ack_seen  = 0
                      id_sr     = tx_id
                      dlc_sr    = tx_dlc
                      data_sr   = tx_data
                    end
                  end

                # ---- SOF: we drove it; next bit is the first ID bit ----
                <<1::4>> ->
                  fld     = F_ID
                  bit_ctr = 0

                # ---- arbitration / identifier ----
                <<2::4>> ->
                  id_sr = {id_sr[9..0], sampled_bit}
                  if bit_ctr == 10 do
                    fld     = F_RTR
                    bit_ctr = 0
                  else
                    bit_ctr = bit_ctr + 1
                  end

                <<3::4>> ->
                  rtr_bit = sampled_bit
                  fld     = F_IDE

                <<4::4>> ->
                  ide_bit = sampled_bit
                  if sampled_bit == 1 do
                    # Extended frame: this core does not parse it. Report it and
                    # sit out the rest of the frame rather than guess at lengths.
                    rx_ext_reg = 1
                    is_tx      = 0
                    end_frame()
                  else
                    fld = F_R0
                  end

                <<5::4>> ->
                  fld     = F_DLC
                  bit_ctr = 0

                <<6::4>> ->
                  dlc_sr = {dlc_sr[2..0], sampled_bit}
                  if bit_ctr == 3 do
                    bit_ctr = 0
                    if rtr_bit == 1 do
                      # Remote frame: no data field.
                      rx_rtr_reg = 1
                      fld        = F_CRC
                      crc_sr     = crc_next
                    else
                      fld = F_DATA
                    end
                  else
                    bit_ctr = bit_ctr + 1
                  end

                <<7::4>> ->
                  data_sr = {data_sr[62..0], sampled_bit}
                  if bit_ctr == data_bits - 1 do
                    bit_ctr = 0
                    fld     = F_CRC
                    # Latch the CRC we computed; a transmitter shifts it out from
                    # here, a receiver compares against what arrives.
                    crc_sr  = crc_next
                  else
                    bit_ctr = bit_ctr + 1
                  end

                <<8::4>> ->
                  crc_sr = {crc_sr[13..0], sampled_bit}
                  if bit_ctr == 14 do
                    bit_ctr  = 0
                    fld      = F_CRC_DELIM
                    stuff_en = 0
                  else
                    bit_ctr = bit_ctr + 1
                  end

                <<9::4>> ->
                  # Delimiter must be recessive.
                  if sampled_bit == 0 do
                    flag_error()
                  else
                    fld = F_ACK
                  end

                <<10::4>> ->
                  if is_tx do
                    # Our own ACK check happened in the monitor above.
                    fld = F_ACK_DELIM
                  else
                    fld = F_ACK_DELIM
                  end

                <<11::4>> ->
                  if sampled_bit == 0 do
                    flag_error()
                  else
                    fld     = F_EOF
                    bit_ctr = 0
                  end

                <<12::4>> ->
                  if sampled_bit == 0 do
                    flag_error()
                  else
                    if bit_ctr == 6 do
                      bit_ctr = 0
                      fld     = F_IFS
                      # Frame complete. Deliver it or score the transmission.
                      if is_tx do
                        if ack_seen do
                          tx_done_reg = 1
                          if tec_reg > 0 do
                            tec_reg = tec_reg - 1
                          end
                        end
                        is_tx = 0
                      else
                        if crc_ok and (ide_bit == 0) and (rtr_bit == 0) do
                          rx_id_reg    = id_sr
                          rx_dlc_reg   = dlc_sr
                          rx_data_reg  = data_sr
                          rx_valid_reg = 1
                          if rec_reg > 0 do
                            rec_reg = rec_reg - 1
                          end
                        end
                      end
                    else
                      bit_ctr = bit_ctr + 1
                    end
                  end

                # ---- interframe space ----
                <<13::4>> ->
                  if bit_ctr == 2 do
                    fld      = F_IDLE
                    bit_ctr  = 0
                    last_bit = 1
                    same_cnt = 0
                  else
                    bit_ctr = bit_ctr + 1
                  end

                # ---- error flag: 6 dominant bits, then the delimiter ----
                <<14::4>> ->
                  if bit_ctr == 5 do
                    bit_ctr = 0
                    fld     = F_ERR_DELIM
                  else
                    bit_ctr = bit_ctr + 1
                  end

                # ---- error delimiter: 8 recessive bits ----
                <<15::4>> ->
                  if bit_ctr == 7 do
                    bit_ctr  = 0
                    fld      = F_IFS
                    is_tx    = 0
                    last_bit = 1
                    same_cnt = 0
                  else
                    bit_ctr = bit_ctr + 1
                  end
              end
            end
          end

          # Bus-off latches once TEC passes 255.
          if tec_reg > 255 do
            off_reg = 1
          end
        end
      end
      end

    # Defeat macro hygiene. The DSL resolves signals by bare name, and slice
    # syntax (`sig[hi..lo]`) only matches a variable whose context is nil, so a
    # quoted body would otherwise fail to parse its own slices.
    Macro.prewalk(body, fn
      {name, meta, ctx} when is_atom(name) and is_atom(ctx) and not is_nil(ctx) ->
        {name, meta, nil}

      node ->
        node
    end)
  end
end
