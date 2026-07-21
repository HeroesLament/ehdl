defmodule Hw.Analysis.Rules.ClockFrequencyRatio do
  @moduledoc """
  Warns when signals cross between clock domains whose frequency ratio
  makes a two-flop synchronizer insufficient or unreliable.

  ## Background

  A two-flop synchronizer (`Hw.CDC.Sync2`) is only reliable when the
  sending signal is stable for at least one full destination clock cycle.
  This means:

  - A signal that is a single-cycle pulse in the **source** domain must
    be held for `ceil(T_dst / T_src)` source cycles to be reliably
    captured. If `freq_src > freq_dst` (fast → slow), a single-cycle
    pulse in the fast domain may be narrower than one slow-clock period
    and will be missed.

  - A signal crossing from a very **slow** domain to a very **fast**
    domain is usually fine for level signals but still warrants checking
    for multi-bit buses.

  ## What is checked

  For every `Hw.CDC.Sync2` instance whose source and destination clocks
  both have declared `freq:` values, this rule checks:

  1. **Fast-to-slow pulse risk** — if `freq_src / freq_dst >= 0.5`, the
     source clock is faster than the destination. Any single-cycle pulse
     from the source is at risk. Emits a warning with the computed ratio.

  2. **Extreme ratio** — if `freq_src / freq_dst >= 4.0`, the source
     pulses are so narrow relative to the destination that even holding
     signals for 2 source cycles may not be enough. Emits an error.

  ## Example diagnostic

      warning[W060]: CDC crossing `:phy_rx_valid_raw` from clk_fast (180 MHz)
                     to clk_48 (48 MHz) — ratio 3.75×
        │
        └─ note: a single-cycle pulse in clk_fast (5.6 ns) is narrower
                 than one clk_48 period (20.8 ns). Use Hw.CDC.PulseSync
                 for event signals, or ensure the signal is held for at
                 least 4 clk_fast cycles before being released.

  ## Priority

  Runs at priority 45, just after CDC crossing detection (40) so it can
  annotate crossings that were already discovered.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.{Diagnostic, Location}

  @impl Hw.Analysis.Rule
  def priority, do: 45

  # freq_src / freq_dst ratios that trigger warnings vs errors
  @warning_ratio 0.9   # src faster than dst by any meaningful amount
  @error_ratio   4.0   # src more than 4× faster than dst — Sync2 very risky

  @sync2_module Hw.CDC.Sync2

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      check_component(comp, comp.clocks)
    end)
  end

  defp check_component(comp, clocks) do
    clock_freq_map = build_freq_map(clocks)

    comp.instances
    |> Enum.filter(&(&1.module == @sync2_module))
    |> Enum.flat_map(fn inst ->
      check_sync2(inst, clock_freq_map, comp)
    end)
  end

  defp check_sync2(inst, clock_freq_map, comp) do
    conns = inst_conns(inst) |> Map.new()

    clk_dst  = Map.get(conns, :clk_dst)
    data_out = Map.get(conns, :data_out)
    data_in  = Map.get(conns, :data_in)

    # Infer source clock from the driving instance in this component
    clk_src = infer_source_clock(data_in, comp)

    with freq_src when freq_src != nil <- Map.get(clock_freq_map, clk_src),
         freq_dst when freq_dst != nil <- Map.get(clock_freq_map, clk_dst) do
      ratio = freq_src / freq_dst
      check_ratio(ratio, freq_src, freq_dst, clk_src, clk_dst, data_in, data_out, inst, comp)
    else
      _ -> []
    end
  end

  defp check_ratio(ratio, freq_src, freq_dst, clk_src, clk_dst, data_in, _data_out, inst, comp)
      when ratio >= @error_ratio do
    loc = inst[:source_location] || fallback(comp.module)
    period_src = Float.round(1000.0 / freq_src, 1)
    period_dst = Float.round(1000.0 / freq_dst, 1)
    ratio_str  = Float.round(ratio, 2)

    [Diagnostic.error(
      :clock_frequency_ratio,
      "CDC on `:#{data_in}` crosses #{clk_src} (#{freq_src} MHz) → " <>
      "#{clk_dst} (#{freq_dst} MHz) at ratio #{ratio_str}× — " <>
      "Hw.CDC.Sync2 is unreliable at this ratio",
      loc,
      context: %{
        signal:    data_in,
        clk_src:   clk_src,
        clk_dst:   clk_dst,
        freq_src:  freq_src,
        freq_dst:  freq_dst,
        ratio:     ratio,
        period_src: period_src,
        period_dst: period_dst
      }
    )]
  end

  defp check_ratio(ratio, freq_src, freq_dst, clk_src, clk_dst, data_in, _data_out, inst, comp)
      when ratio >= @warning_ratio do
    loc = inst[:source_location] || fallback(comp.module)
    period_src = Float.round(1000.0 / freq_src, 1)
    period_dst = Float.round(1000.0 / freq_dst, 1)
    ratio_str  = Float.round(ratio, 2)

    [Diagnostic.warning(
      :clock_frequency_ratio,
      "CDC on `:#{data_in}` crosses #{clk_src} (#{freq_src} MHz) → " <>
      "#{clk_dst} (#{freq_dst} MHz), ratio #{ratio_str}× — " <>
      "single-cycle pulses (#{period_src} ns) may be missed by #{clk_dst} (#{period_dst} ns period)",
      loc,
      context: %{
        signal:    data_in,
        clk_src:   clk_src,
        clk_dst:   clk_dst,
        freq_src:  freq_src,
        freq_dst:  freq_dst,
        ratio:     ratio,
        period_src: period_src,
        period_dst: period_dst
      }
    )]
  end

  defp check_ratio(_ratio, _src, _dst, _cs, _cd, _di, _do, _inst, _comp), do: []

  # Walk through instances to find which one drives data_in and what clock it uses
  defp infer_source_clock(data_in, comp) when is_atom(data_in) do
    clock_port_names = [:clk, :clk_48mhz, :clk_fast, :clock, :clk_src]

    Enum.find_value(comp.instances, fn inst ->
      conns = inst_conns(inst) |> Map.new()
      # Is data_in an output of this instance?
      output_wires = Map.values(conns) |> Enum.filter(&is_atom/1)
      if data_in in output_wires do
        # What clock is this instance on?
        Enum.find_value(clock_port_names, fn port ->
          Map.get(conns, port)
        end)
      end
    end)
  end

  defp infer_source_clock(_, _), do: nil

  defp build_freq_map(clocks) do
    clocks
    |> Enum.filter(&(&1.freq_mhz != nil))
    |> Map.new(&{&1.name, &1.freq_mhz})
  end

  defp inst_conns(%{ports: ports}) when is_list(ports), do: ports
  defp inst_conns(%{connections: conns}) when is_list(conns), do: conns
  defp inst_conns(_), do: []

  defp fallback(module),
    do: %Location{file: "unknown", line: 0, module: module}
end
