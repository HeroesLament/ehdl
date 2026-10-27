defmodule Hw.Target do
  @moduledoc """
  Per-device structural budgets, the single source of thresholds for
  `mix hw.census` (and, later, the structural `hw.check` rules).

  Budgets come from measured place-and-route runs, not datasheets. For
  xc7z020 with nextpnr-himbaechel router2 (OpenOcuSync RX/PHY, 2026-10):

    * LUT-input fanout is the binding limit. v4 (nets of 1033 / 1029 / 513
      LUT inputs) did not route; v5 (max 299) routed in 88 s. Hard gate 300,
      new data selects should stay at or below 64.
    * Utilisation alone does not predict routability, but the PHY at
      ~25k yosys LUTs (LUTX ~37%) is near the edge of what routes without
      seed sensitivity. `lut_util` warns at 50% of the device's LUTs.
    * Control sets are cheap on this design; the budget is a warning only.

      target = Hw.Target.get(:xc7z020)
      Hw.Target.check(census, target)
  """

  alias Hw.Census

  defstruct name: nil,
            part: nil,
            capacity: %{},
            lut_input_fanout: [max: 300, warn: 64],
            control_sets: [warn: 400],
            lut_util: [warn: 0.50],
            util: [warn: 0.90]

  @type t :: %__MODULE__{}

  @type finding :: %{
          level: :error | :warning,
          metric: atom(),
          value: number(),
          limit: number(),
          message: String.t()
        }

  @doc "Budget for a known device."
  @spec get(atom()) :: t()
  def get(:xc7z020) do
    %__MODULE__{
      name: :xc7z020,
      part: "xc7z020clg400-1",
      capacity: %{lut: 53_200, ff: 106_400, dsp: 220, bram36: 140}
    }
  end

  def get(name), do: raise(ArgumentError, "no Hw.Target budget for #{inspect(name)}")

  @doc "Known device names."
  @spec known() :: [atom()]
  def known, do: [:xc7z020]

  @doc """
  Check a census against a target. Returns findings, errors first.

  Errors: any net over `lut_input_fanout[:max]`, any resource over 100%.
  Warnings: nets over `lut_input_fanout[:warn]`, LUT utilisation over
  `lut_util[:warn]`, other resources over `util[:warn]`, control sets over
  `control_sets[:warn]`.
  """
  @spec check(Census.t(), t()) :: [finding()]
  def check(%Census{} = c, %__MODULE__{} = t) do
    res = Census.resources(c)
    used = %{lut: res.lut, ff: res.ff, dsp: res.dsp, bram36: res.ramb36 + res.ramb18 / 2}

    fanout_findings(c, t) ++
      util_findings(used, t) ++
      control_set_findings(c, t)
  end

  @doc "True when the findings contain an error."
  @spec errors?([finding()]) :: boolean()
  def errors?(findings), do: Enum.any?(findings, &(&1.level == :error))

  defp fanout_findings(c, t) do
    max = t.lut_input_fanout[:max]
    warn = t.lut_input_fanout[:warn]
    over_max = Census.nets_above(c, max)
    over_warn = Census.nets_above(c, warn)
    peak = Census.max_lut_fanout(c)

    errors =
      if over_max > 0 do
        [
          %{
            level: :error,
            metric: :lut_input_fanout,
            value: peak,
            limit: max,
            message: "#{over_max} net(s) over #{max} LUT inputs (max #{peak})"
          }
        ]
      else
        []
      end

    warnings =
      if over_warn > over_max do
        [
          %{
            level: :warning,
            metric: :lut_input_fanout,
            value: over_warn - over_max,
            limit: warn,
            message: "#{over_warn - over_max} net(s) over #{warn} LUT inputs (max #{peak})"
          }
        ]
      else
        []
      end

    errors ++ warnings
  end

  defp util_findings(used, t) do
    Enum.flat_map([:lut, :ff, :dsp, :bram36], fn r ->
      cap = Map.fetch!(t.capacity, r)
      frac = used[r] / cap
      warn = if r == :lut, do: t.lut_util[:warn], else: t.util[:warn]
      pct = Float.round(frac * 100, 1)

      cond do
        frac > 1.0 ->
          [%{level: :error, metric: r, value: frac, limit: 1.0, message: "#{r} #{used[r]} / #{cap} (#{pct}%) exceeds the device"}]

        frac > warn ->
          [%{level: :warning, metric: r, value: frac, limit: warn, message: "#{r} #{used[r]} / #{cap} (#{pct}%) over #{round(warn * 100)}%"}]

        true ->
          []
      end
    end)
  end

  defp control_set_findings(c, t) do
    sets = Census.control_set_summary(c).sets
    warn = t.control_sets[:warn]

    if sets > warn do
      [%{level: :warning, metric: :control_sets, value: sets, limit: warn, message: "#{sets} control sets over #{warn}"}]
    else
      []
    end
  end
end
