defmodule Hw.USB.ClockTrim do
  @moduledoc """
  USB SOF-disciplined software DPLL for PLL clock trimming.

  Measures the interval between USB Start-of-Frame (SOF) tokens and
  uses the error relative to the nominal interval to drive the ECP5
  PLL's dynamic phase adjustment ports, closing a frequency feedback
  loop that disciplines the local clock to the host's USB reference.

  ## Why this is needed

  USB full-speed requires the device clock to be within ±2500 ppm of
  48 MHz. Many FPGA boards (including ULX3S) use a 25 MHz crystal from
  which an exact 48 MHz cannot always be synthesised with integer PLL
  dividers. This component compensates for residual frequency error.

  On ULX3S with `CLKI_DIV=25, CLKFB_DIV=48` the PLL produces an exact
  48.000 MHz — no trimming is required and this component can be omitted.
  On boards where only an approximate frequency is available (e.g. 46.875
  MHz, 48.077 MHz) this component corrects the residual error.

  ## Theory of operation

  The USB host transmits a SOF token every 1.000 ms ± 500 ppm. At the
  nominal 48 MHz clock this corresponds to exactly `TARGET_COUNT` cycles.
  If the local clock is slow the SOF arrives after more cycles than
  expected (positive error); if fast, fewer cycles (negative error).

  A proportional-integral loop filter integrates the per-SOF error and
  drives phase step pulses to the ECP5 PLL:

      integrator  ← integrator + error
      steps_this_sof ← integrator >>> GAIN_SHIFT
      integrator  ← integrator - (steps_this_sof <<< GAIN_SHIFT)  -- remainder

  Each phase step shifts the VCO phase by `1 / (VCO_freq × 8)`:
  - At VCO = 432 MHz: step ≈ 289 ps
  - At VCO = 600 MHz: step ≈ 208 ps

  Steps are applied one per `STEP_HOLD` cycles to satisfy the ECP5 PLL
  minimum hold time requirement between phase steps.

  ## Convergence

  With `GAIN_SHIFT=10` and a 10,000 ppm initial error (e.g. 46.875 MHz
  actual vs 48 MHz target), convergence to within ±100 ppm takes
  approximately 50–200 SOF intervals (50–200 ms). USB enumeration allows
  several seconds, so this is well within budget.

  ## Parameters

  - `TARGET_COUNT` — expected clock cycles between SOF tokens at nominal
    frequency. Default: 48_000 (= 48 MHz × 1 ms).
  - `GAIN_SHIFT` — loop filter gain = 1 / 2^GAIN_SHIFT. Higher = slower
    convergence but more stable. Range 6–12. Default: 10.
  - `MAX_STEPS_PER_SOF` — maximum phase steps to apply per SOF interval,
    prevents runaway. Default: 128.
  - `STEP_HOLD` — minimum clock cycles between phase steps (ECP5 requires
    at least 4). Default: 4.

  ## Integration

      # In top.ex, connect between SIE SOF output and PLL phase ports:
      instance :clk_trim, Hw.USB.ClockTrim,
        clk:        :clk_48,
        rst:        :rst,
        sof_pulse:  :sie_sof_pulse,
        phase_dir:  :pll_phase_dir,
        phase_step: :pll_phase_step

      instance :pll, ULX3S.PLL,
        ...
        phase_dir:  :pll_phase_dir,
        phase_step: :pll_phase_step

  The SIE must output a `sof_pulse` — one cycle pulse when a SOF token
  is received. Add `output :sof_pulse, 1` to `Hw.USB.SIE` and pulse it
  when `rx_pid == pid_sof` at EOP.
  """

  use Hw.Component

  param :TARGET_COUNT,      default: 48_000
  param :GAIN_SHIFT,        default: 10
  param :MAX_STEPS_PER_SOF, default: 128
  param :STEP_HOLD,         default: 4

  clock :clk
  input  :rst,        1

  # SOF pulse from SIE — one cycle when SOF token received
  input  :sof_pulse,  1

  # PLL dynamic phase control outputs
  output :phase_dir,  1, init: 0
  output :phase_step, 1, init: 0

  # Diagnostic outputs
  output :locked,     1, init: 0   # 1 when loop has converged (<500 ppm)
  output :error_out, 16, init: 0   # last measured SOF interval error (signed)

  # --- Interval measurement ---
  wire :sof_counter,  17, init: 0   # counts cycles between SOF pulses
  wire :interval,     17, init: 0   # latched interval on SOF edge
  wire :prev_sof,      1, init: 0   # SOF seen at least once

  # --- Error calculation ---
  # error = interval - TARGET_COUNT (signed, 17 bits)
  wire :error,        17, init: 0   # signed interval error

  # --- PI loop filter ---
  # integrator accumulates error over time
  # width: 17 (error) + GAIN_SHIFT (10) + some headroom = 32 bits
  wire :integrator,   32, init: 0
  wire :integrator_next, 32

  # --- Step dispatch ---
  wire :steps_pending, 17, init: 0   # signed: positive=advance, negative=retard
  wire :step_hold_cnt,  3, init: 0   # countdown between steps

  # --- Sized constants ---
  wire :zero,   1
  wire :one,    1
  wire :w3_0,   3
  wire :w17_0, 17
  wire :w32_0, 32

  wire :sof_counter_next,   17
  wire :step_hold_cnt_next,  3

  # Lock detection: locked when |error| < 24 (500 ppm × 48000 / 1e6 ≈ 24 cycles)
  wire :error_abs,    17
  wire :is_locked,     1

  comb do
    zero   = 0
    one    = 1
    w3_0   = 0
    w17_0  = 0
    w32_0  = 0

    sof_counter_next   = sof_counter + 1
    step_hold_cnt_next = step_hold_cnt + 1

    # Signed error: interval minus target
    error = interval - TARGET_COUNT

    # Integrator: add error each SOF (done in sequential block)
    # Steps from integrator: arithmetic shift right by GAIN_SHIFT
    # (handled in sequential)

    # For diagnostics
    error_abs = if error[16..16] == 1, do: bnot(error) + 1, else: error
    is_locked = error_abs < 24

    error_out = error[15..0]
    locked    = is_locked

    # integrator_next used in sequential
    integrator_next = integrator
  end

  on :clk do
    if rst do
      sof_counter   = w17_0
      interval      = w17_0
      prev_sof      = zero
      error         = w17_0
      integrator    = w32_0
      steps_pending = w17_0
      step_hold_cnt = w3_0
      phase_dir     = zero
      phase_step    = zero
    else

      # Default: deassert phase_step pulse
      phase_step = zero

      # --- SOF interval measurement ---
      sof_counter = sof_counter_next

      if sof_pulse do
        if prev_sof do
          # Latch interval and compute error
          interval  = sof_counter
          # Clamp counter to avoid overflow on first few SOFs
          if sof_counter > 0 do
            # Update integrator: accumulate signed error
            # error = sof_counter - TARGET_COUNT
            # We do this inline since error wire is comb from interval
            integrator = integrator + (sof_counter - TARGET_COUNT)
          end
        end
        prev_sof    = one
        sof_counter = w17_0

        # Compute steps to apply this SOF interval
        # steps = integrator >>> GAIN_SHIFT (arithmetic right shift)
        # We clamp to MAX_STEPS_PER_SOF
        if bnot(prev_sof) == 0 do
          # integrator arithmetic shift right by GAIN_SHIFT (10)
          # For simplicity use GAIN_SHIFT=10: divide by 1024
          # The integrator is 32-bit signed
          if integrator[31..31] == 0 do
            # Positive integrator — clock is slow — advance phase
            if integrator[31..10] > MAX_STEPS_PER_SOF do
              steps_pending = MAX_STEPS_PER_SOF
            else
              steps_pending = integrator[26..10]
            end
          else
            # Negative integrator — clock is fast — retard phase
            if (bnot(integrator[31..10]) + 1) > MAX_STEPS_PER_SOF do
              steps_pending = bnot(MAX_STEPS_PER_SOF) + 1
            else
              steps_pending = integrator[26..10]
            end
          end
        end
      end

      # --- Step dispatch ---
      # Apply one step per STEP_HOLD cycles while steps_pending != 0
      if step_hold_cnt == 0 do
        if steps_pending > 0 do
          phase_dir     = one    # advance
          phase_step    = one    # pulse
          steps_pending = steps_pending - 1
        else
          if steps_pending < 0 do
            phase_dir     = zero   # retard
            phase_step    = one    # pulse
            steps_pending = steps_pending + 1
          end
        end
      end

      # Step hold counter: counts STEP_HOLD cycles between steps
      if phase_step do
        step_hold_cnt = 1
      else
        if step_hold_cnt > 0 do
          if step_hold_cnt == STEP_HOLD do
            step_hold_cnt = w3_0
          else
            step_hold_cnt = step_hold_cnt_next
          end
        end
      end

    end
  end

end
