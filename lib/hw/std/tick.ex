defmodule Hw.Std.Tick do
  @moduledoc """
  Periodic strobe generator (clock-enable / prescaler).

  Emits `tick` high for exactly one `clk` cycle every `CYCLES` clocks. The
  design stays in one clock domain: consumers gate on `tick` instead of
  running from a divided clock.

  ## Parameters

    * `CYCLES` - clocks between ticks, at least 2 when built through
      `config/2`.

  Use `config/2` to derive it from real units:

      Hw.Std.Tick.config(25_000_000, ms: 10)   #=> [CYCLES: 250_000]
      Hw.Std.Tick.config(25_000_000, us: 40)   #=> [CYCLES: 1_000]
      Hw.Std.Tick.config(25_000_000, 10)       #=> [CYCLES: 250_000] (bare integer is ms)

  ## Timing

  The counter starts at `CYCLES - 1` and counts down to 0. `tick` is
  registered and is high in the cycle after the counter reloads, so ticks are
  exactly `CYCLES` clocks apart and the first one appears `CYCLES` clocks
  after reset release.

  The period is exact in clock cycles. Wall-clock accuracy is that of the
  oscillator driving `clk`, and this is an interval timer, not a time-of-day
  source.

  ## Inputs

    * `rst` - synchronous; restarts the period and clears `tick`.
  """

  use Hw.Component

  param :CYCLES, default: 25_000

  clock :clk
  input :rst, 1
  output :tick, 1

  wire :cnt, clog2(CYCLES + 1)

  on :clk do
    if rst do
      cnt = CYCLES - 1
      tick = 0
    else
      if cnt == 0 do
        cnt = CYCLES - 1
        tick = 1
      else
        cnt = cnt - 1
        tick = 0
      end
    end
  end

  @units %{s: 1_000_000_000, ms: 1_000_000, us: 1_000, ns: 1}

  @doc """
  Params for a tick every `period` on a `clk_hz` clock.

  `period` is one of `s:`, `ms:`, `us:` or `ns:` (integers), or a bare integer
  meaning milliseconds.

  The period must be a whole number of clocks and at least 2. The smallest
  step is one clock period, so a 25 MHz clock cannot make a 7 ns tick; the
  error says what the step is.
  """
  def config(clk_hz, [{unit, n}]) when is_integer(clk_hz) and clk_hz > 0 and is_integer(n) and n > 0 do
    scale = Map.get(@units, unit) || raise ArgumentError, "unknown unit #{inspect(unit)}, use s, ms, us or ns"
    period_ns = n * scale
    total = clk_hz * period_ns

    if rem(total, 1_000_000_000) != 0 do
      step_ns = 1_000_000_000 / clk_hz

      raise ArgumentError,
            "#{n} #{unit} is not a whole number of clocks at #{clk_hz} Hz " <>
              "(one clock is #{step_ns} ns, so periods must be a multiple of that)"
    end

    cycles = div(total, 1_000_000_000)

    if cycles < 2 do
      raise ArgumentError, "#{n} #{unit} at #{clk_hz} Hz is #{cycles} clocks, need at least 2"
    end

    [CYCLES: cycles]
  end

  def config(clk_hz, period_ms) when is_integer(period_ms), do: config(clk_hz, ms: period_ms)
end
