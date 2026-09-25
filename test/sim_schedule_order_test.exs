defmodule SimScheduleOrderTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Invariant: the simulator evaluates each entity's comb ops in ONE pass, in
  # schedule order. That is only correct if the order is topological: no op
  # may read a comb-produced signal before the op that produces it.
  #
  # Violated until 2026-09-24. Hw.Sim.Schedule's dependency extractors were
  # hand-enumerated per op type; Gte, Lte, Neq, shifts, extends, Mul/Div/Mod,
  # reductions, Popcount... had no clauses, so topo_sort saw them as having no
  # inputs and no output and placed them arbitrarily. The full-ETS-snapshot
  # env hid it (a forward reference silently read the previous edge's value);
  # the M0 targeted env exposed it as Hw.AXIHPReader's FSM never leaving
  # :idle (`fill >= 128` and `rlast != is_last_beat` read before produced).
  #
  # This test checks the order itself, independently of any env strategy, so
  # neither a future op type nor a future env optimisation can reintroduce it
  # silently.
  # ---------------------------------------------------------------------------

  alias Hw.IR.Ops.{Reg, Mem, Blackbox, Assign}
  alias Hw.IR.Types.Signal

  # Components chosen for operator coverage: Gte/Neq/Sub/BitAnd (reader),
  # the writer (large FSM), Shr/Neq (FIFO), Shr/BitXor gray code (stream
  # BRAM FIFO). Add a component here when it introduces an op type.
  @components [Hw.AXIHPReader, Hw.AXIHPWriter, Hw.FIFO, Hw.StreamBRAMFIFO]

  for mod <- @components do
    test "#{inspect(mod)}: every entity's comb order is topological" do
      mod = unquote(mod)
      design = Hw.Compile.Elaborate.elaborate(mod)
      schedule = Hw.Sim.Schedule.build(design, mod)

      for {name, entity} <- schedule.entities do
        assert forward_refs(entity.ops) == [],
               "#{inspect(mod)} entity #{inspect(name)}: reads before produce " <>
                 inspect(forward_refs(entity.ops))
      end
    end
  end

  # Returns [{consumer_output, [signals read before produced]}]. Mirrors the
  # comb filter Hw.Sim.Entity.init/1 applies before evaluating.
  defp forward_refs(ops) do
    regs = for %Reg{output: o} <- ops, into: MapSet.new(), do: o.name

    comb =
      Enum.reject(ops, fn op ->
        match?(%Reg{}, op) or match?(%Mem{}, op) or match?(%Blackbox{}, op) or
          (match?(%Assign{}, op) and MapSet.member?(regs, op.output.name))
      end)

    produced = comb |> Enum.flat_map(&outs/1) |> MapSet.new()

    {_, bad} =
      Enum.reduce(comb, {MapSet.new(), []}, fn op, {done, acc} ->
        early =
          for r <- reads(op), MapSet.member?(produced, r), not MapSet.member?(done, r), do: r

        acc = if early == [], do: acc, else: [{hd(outs(op) ++ [:unnamed]), early} | acc]
        {MapSet.union(done, MapSet.new(outs(op))), acc}
      end)

    Enum.reverse(bad)
  end

  defp outs(%{output: %Signal{name: n}}), do: [n]
  defp outs(_), do: []

  defp reads(op) do
    op |> Map.from_struct() |> Map.drop([:output]) |> signals([]) |> Enum.uniq()
  end

  defp signals(%Signal{name: n}, acc), do: [n | acc]
  defp signals(%_{} = s, acc), do: signals(Map.from_struct(s), acc)
  defp signals(%{} = m, acc), do: Enum.reduce(m, acc, fn {_k, v}, a -> signals(v, a) end)
  defp signals(l, acc) when is_list(l), do: Enum.reduce(l, acc, &signals/2)
  defp signals({a, b}, acc), do: signals(a, signals(b, acc))
  defp signals(_, acc), do: acc
end
