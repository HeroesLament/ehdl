defmodule Hw.Analysis.Rules.ShiftLine do
  @moduledoc """
  Detects long flip-flop delay lines that yosys cannot turn into SRLs.

  ## Background (routability guide R4)

  A chain of registers where each loads the previous one (optionally under
  a shared enable) is a delay line. yosys maps such a chain to SRL16/SRL32
  on its own when it has no reset and nothing reads the middle stages: the
  PHY's 32-deep FFT delay lines come out as SRLC32E with no help. A chain
  with a reset or with middle taps stays in flip-flops: a 64-deep line of
  38-bit samples is 2432 FFs on one CE net (LtfSync before it became 16
  RAM32M banks with a rotating pointer).

  ## What is reported

  Chains at least 16 registers deep that have a reset or a middle tap.
  Hint below 256 flip-flops, warning from 256.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.{Diagnostic, Structure}
  alias Hw.IR.Ops.{Mux, Reg}
  alias Hw.IR.Types.{Const, Signal}

  @min_depth 16
  @warn_ffs 256

  @impl Hw.Analysis.Rule
  def priority, do: 70

  @impl Hw.Analysis.Rule
  def stage, do: :ir

  @impl Hw.Analysis.Rule
  def run(%{ops: ops} = design) do
    drivers = Structure.drivers(design)
    uses = Structure.use_counts(design)
    regs = for %Reg{output: %Signal{name: n}} = r <- ops, into: %{}, do: {n, r}

    # prev register name -> next register name
    next =
      Enum.reduce(regs, %{}, fn {name, r}, acc ->
        case loads_from(r, drivers, regs) do
          nil -> acc
          prev -> Map.put(acc, prev, name)
        end
      end)

    heads = Map.keys(next) -- Map.values(next)

    heads
    |> Enum.map(&chain(&1, next, [&1]))
    |> Enum.filter(&(length(&1) >= @min_depth))
    |> Enum.flat_map(fn chain ->
      why = blockers(chain, regs, drivers, uses)
      if why == [], do: [], else: [diagnostic(design, chain, regs, why)]
    end)
  end

  # Why yosys cannot map the chain to SRLs.
  defp blockers(chain, regs, drivers, uses) do
    reset = Enum.any?(chain, &Structure.reset?(regs[&1], drivers))
    # A middle stage is read once by the next stage's load, plus once by its
    # own enable-hold mux (`default` = itself) when it has one. More is a tap.
    taps =
      chain
      |> Enum.drop(-1)
      |> Enum.count(fn name ->
        Map.get(uses, name, 0) - self_reads(regs[name], drivers) > 1
      end)

    []
    |> then(&if(reset, do: ["reset" | &1], else: &1))
    |> then(&if(taps > 0, do: ["#{taps} middle tap(s)" | &1], else: &1))
  end

  # 1 when the register holds through its own mux chain (it reads itself).
  defp self_reads(%Reg{output: %Signal{name: self}} = r, drivers) do
    case Structure.reg_chain(r, drivers) do
      {[_ | _], %Signal{name: ^self}} -> 1
      _ -> 0
    end
  end

  # The register that `r` loads: directly, or as the only non-constant value
  # in a mux chain that otherwise holds (`if en do r = prev end`, with or
  # without a constant clear around it).
  defp loads_from(%Reg{output: %Signal{name: self}} = r, drivers, regs) do
    case Structure.reg_chain(r, drivers) do
      {[], %Signal{name: p}} when p != self ->
        if Map.has_key?(regs, p), do: p

      {[_ | _] = muxes, %Signal{name: ^self}} ->
        # Ignore arms that just pass the inner mux through (an `if` block
        # that does not assign this register still wraps it in a mux).
        inner = MapSet.new(muxes, & &1.output.name)

        values =
          for %Mux{cases: cs} <- muxes,
              {_c, v} <- cs,
              not match?(%Const{}, v),
              not (match?(%Signal{}, v) and MapSet.member?(inner, v.name)),
              do: v

        case values do
          [%Signal{name: p}] when p != self -> if Map.has_key?(regs, p), do: p
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp chain(name, next, acc) do
    case Map.get(next, name) do
      nil -> Enum.reverse(acc)
      n -> if n in acc, do: Enum.reverse(acc), else: chain(n, next, [n | acc])
    end
  end

  defp diagnostic(design, chain, regs, why) do
    depth = length(chain)
    ffs = chain |> Enum.map(&Structure.width(regs[&1].output)) |> Enum.sum()
    first = hd(chain)
    last = List.last(chain)

    msg =
      "#{depth}-deep register delay line (#{ffs} FFs) from `:#{first}` to `:#{last}` " <>
        "stays in flip-flops (#{Enum.join(why, ", ")}); drop the reset / taps so yosys " <>
        "maps it to SRLs, or use a LUTRAM bank or BRAM ring"

    fun = if ffs >= @warn_ffs, do: &Diagnostic.warning/4, else: &Diagnostic.hint/4

    fun.(:shift_line, msg, Structure.location(design, first),
      context: %{depth: depth, ffs: ffs, first: first, last: last, blockers: why, module: design.name}
    )
  end
end
