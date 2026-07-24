defmodule Hw.Optimize.Passes.CSE do
  @moduledoc """
  Common Subexpression Elimination — value numbering modulo hardware algebra.

  The elaborator emits the same value in slightly different syntactic shapes at
  many sites (the `rev8` 8-bit bit-reversal cone is open-coded at ~6 places in
  the SIE, buried in different mux branches). yosys can't always share these
  because they're structurally distinct by the time it sees flattened Verilog.
  CSE canonicalises each pure combinational op and, when two ops compute the
  same value, keeps one and rewrites every use of the dead output onto the
  survivor — draining the duplicated-cone logic directly.

  ## Algorithm (single linear pass + one final rewrite)

  1. Walk ops in dataflow (topological) order, so an op is canonicalised only
     after the ops it depends on.
  2. Maintain a **substitution map** `subst : dead_signal_name -> survivor
     %Signal{}` (with path compression). Each operand signal is resolved
     through `subst` *before* it goes into a key, so an op reading a
     since-eliminated signal keys against its survivor for free — no need to
     rewrite the whole design between merges.
  3. Compute a canonical key for each PURE op:
     `{op_tag, normalized_operands, literal_params}`.
     **Normalization** (the crux — without it most real duplication is missed):
       * commutative ops (BitAnd/BitOr/BitXor/Add/Mul/Eq/Neq/Min/Max) sort operands;
       * an identity `Slice` (full-width `x[w-1:0]`) is an alias for `x`;
       * a single-element `Concat` is an alias for its element.
     The two alias cases don't get a key — the op's output is substituted
     straight onto the (resolved) aliased signal.
  4. When two ops share a key, the earlier op's output is the survivor and the
     later op's output name is entered into `subst`.
  5. **Once, at the end:** rewrite every surviving op's operands through the
     fully-resolved `subst`, drop the eliminated ops, and prune their now-dead
     internal signal declarations.

  This is O(N·α) rather than O(N·merges): the whole-design rewrite happens a
  single time instead of once per elimination.

  ## Safety

  Only PURE, single-output combinational ops are eligible. `Reg`, `Mem*`,
  `Blackbox`, `Tristate`, and the dual-output `Complex*` ops are NEVER deduped.
  We only ever eliminate an op whose output is an INTERNAL wire, so no top-level
  port is left without a driver. Substitution targets are always `%Signal{}`
  (never a `%Const{}`), so no illegal-Verilog bit-select-of-literal can arise.
  """

  @behaviour Hw.Optimize.Pass

  alias Hw.IR.Design
  alias Hw.IR.Types.{Signal, Const, ParamRef}
  alias Hw.Optimize.Pass

  alias Hw.IR.Ops.{
    Add, Sub, Mul, Div, Mod, Min, Max, MulRound,
    BitAnd, BitOr, BitNot, BitXor, Shl, Shr, Shra,
    ReduceAnd, ReduceOr, ReduceXor, Popcount, Neg, Abs, Clog2,
    SignExtend, ZeroExtend, ReverseBits,
    Eq, Neq, Lt, Gt, Lte, Gte,
    Slice, Concat, Replicate, Cast, Assign, Mux
  }

  @impl true
  def name, do: :cse

  # Ops CSE may dedupe: pure, combinational, single Signal output.
  # MemRead is excluded (memory is stateful). Assign is eligible (pure wire).
  @pure_ops [
    Add, Sub, Mul, Div, Mod, Min, Max, MulRound,
    BitAnd, BitOr, BitNot, BitXor, Shl, Shr, Shra,
    ReduceAnd, ReduceOr, ReduceXor, Popcount, Neg, Abs, Clog2,
    SignExtend, ZeroExtend, ReverseBits,
    Eq, Neq, Lt, Gt, Lte, Gte,
    Slice, Concat, Replicate, Cast, Assign, Mux
  ]

  # Commutative binary ops — operands sorted in the key so `a op b` == `b op a`.
  @commutative [BitAnd, BitOr, BitXor, Add, Mul, Eq, Neq, Min, Max]

  @impl true
  def run(%Design{} = design, _opts) do
    def_of = Pass.def_of(design)
    order = topo_order(design, def_of)
    # A signal may be eliminated only if it is an internal wire AND is not
    # "pinned" — i.e. referenced somewhere OTHER than an op operand field, where
    # the CSE dataflow graph can't see the reference. Clocks and reset signals
    # are emitted by NAME into `always`/`if (rst)` blocks (see
    # Hw.Emit.Verilog.Sequential), so eliminating them silently breaks the
    # design even though the graph shows no users.
    eliminable_names =
      design
      |> internal_name_set()
      |> MapSet.difference(Pass.pinned_names(design))

    # subst : dead_name -> survivor %Signal{}   (path-compressed on read)
    # vtable: canonical_key -> survivor %Signal{}
    {subst, _vtable} =
      Enum.reduce(order, {%{}, %{}}, fn op_name, {subst, vtable} ->
        op = Map.get(def_of, op_name)

        cond do
          is_nil(op) or not eliminable?(op, eliminable_names) ->
            {subst, vtable}

          alias_target = alias_of(op) ->
            # Identity slice / single-element concat: output aliases its input
            # (resolved through subst so we follow prior eliminations).
            {survivor, subst} = resolve(subst, alias_target)
            {Map.put(subst, op_name, survivor), vtable}

          true ->
            {key, subst} = canonical_key(op, subst)

            case Map.get(vtable, key) do
              nil ->
                {subst, Map.put(vtable, key, output_signal(op))}

              survivor ->
                {Map.put(subst, op_name, survivor), vtable}
            end
        end
      end)

    apply_substitution(design, subst)
  end

  # ---------------------------------------------------------------------------
  # Substitution resolution (union-find with path compression)
  # ---------------------------------------------------------------------------

  # Resolve a value through subst. A %Signal{} whose name is a subst key follows
  # the chain to the final survivor; anything else (Const, ParamRef, int) is
  # returned as-is. Returns {resolved_value, updated_subst} (compression writes).
  defp resolve(subst, %Signal{name: name} = sig) do
    case Map.get(subst, name) do
      nil ->
        {sig, subst}

      %Signal{} = target ->
        {final, subst} = resolve(subst, target)
        # Path compression: point name straight at the final survivor.
        {final, Map.put(subst, name, final)}
    end
  end

  defp resolve(subst, other), do: {other, subst}

  # ---------------------------------------------------------------------------
  # Eligibility & aliasing
  # ---------------------------------------------------------------------------

  # Eliminable = pure op whose output name is in `eliminable_names` (internal
  # wires minus pinned clock/reset signals).
  defp eliminable?(%mod{} = op, eliminable_names) do
    mod in @pure_ops and MapSet.member?(eliminable_names, output_signal(op).name)
  end

  defp internal_name_set(%Design{signals: signals}) do
    for s <- signals, s.direction == :internal, into: MapSet.new(), do: s.name
  end

  defp output_signal(%{output: %Signal{} = s}), do: s

  # Identity slice: x[hi:lo] where lo==0 and hi==width(x)-1 (full span) -> x.
  defp alias_of(%Slice{input: %Signal{width: w} = src, hi: hi, lo: lo})
       when is_integer(w) do
    if index_int(lo) == 0 and index_int(hi) == w - 1, do: src, else: nil
  end

  # Single-element concat of a signal -> that signal.
  defp alias_of(%Concat{inputs: [%Signal{} = only]}), do: only

  defp alias_of(_), do: nil

  defp index_int(%Const{value: v}) when is_integer(v), do: v
  defp index_int(v) when is_integer(v), do: v
  defp index_int(_), do: :dynamic

  # ---------------------------------------------------------------------------
  # Canonical keys (operands resolved through subst first)
  # ---------------------------------------------------------------------------

  defp canonical_key(%mod{} = op, subst) do
    {resolved, subst} =
      op
      |> Pass.operand_values()
      |> Enum.map_reduce(subst, fn v, s -> resolve(s, v) end)

    operands = Enum.map(resolved, &norm_value/1)

    operands =
      if mod in @commutative and length(operands) == 2 do
        Enum.sort(operands)
      else
        operands
      end

    {{op_tag(mod), operands, literal_params(op)}, subst}
  end

  defp op_tag(mod), do: mod |> Module.split() |> List.last() |> String.to_atom()

  defp norm_value(%Signal{name: name}), do: {:sig, name}
  defp norm_value(%Const{value: v, width: w, signed: s}), do: {:const, v, w, s}
  defp norm_value(%ParamRef{name: name}), do: {:param, name}
  defp norm_value(v) when is_integer(v), do: {:int, v}
  defp norm_value(other), do: {:other, other}

  defp literal_params(%Slice{hi: hi, lo: lo}), do: {:slice, index_int(hi), index_int(lo)}
  defp literal_params(%Cast{kind: kind}), do: {:cast, kind}
  defp literal_params(%Replicate{count: c}), do: {:rep, c}
  defp literal_params(%SignExtend{width: w}), do: {:sext, w}
  defp literal_params(%ZeroExtend{width: w}), do: {:zext, w}
  defp literal_params(%MulRound{shift: s}), do: {:mulround, s}
  defp literal_params(%Mux{cases: cases}), do: {:mux, length(cases)}
  defp literal_params(_), do: nil

  # ---------------------------------------------------------------------------
  # Final rewrite: apply subst to every surviving op, drop dead ops & signals
  # ---------------------------------------------------------------------------

  defp apply_substitution(%Design{} = design, subst) when map_size(subst) == 0 do
    design
  end

  defp apply_substitution(%Design{signals: signals} = design, subst) do
    dead = MapSet.new(Map.keys(subst))

    # Fully compress subst so every dead name maps directly to a live survivor.
    final = Map.new(subst, fn {name, _} -> {name, follow(subst, name)} end)

    # Drop eliminated ops (those whose output is a dead name), then remap all
    # remaining ops' operands through `final` in a single O(ops) walk.
    kept_ops =
      Enum.reject(design.ops, fn op ->
        Enum.any?(Pass.output_names(op), &MapSet.member?(dead, &1))
      end)

    %Design{ops: new_ops} =
      Pass.rewrite_uses_map(%{design | ops: kept_ops}, final)

    new_signals =
      Enum.reject(signals, fn s ->
        MapSet.member?(dead, s.name) and s.direction == :internal
      end)

    %{design | ops: new_ops, signals: new_signals}
  end

  # Follow a subst chain to its terminal %Signal{}.
  defp follow(subst, name) do
    case Map.get(subst, name) do
      %Signal{name: next} = sig ->
        if Map.has_key?(subst, next), do: follow(subst, next), else: sig

      nil ->
        raise "CSE: dangling substitution for #{inspect(name)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Topological order over the dataflow graph (Kahn, O(V+E))
  # ---------------------------------------------------------------------------

  defp topo_order(%Design{}, def_of) do
    names = Map.keys(def_of)

    dep_lists =
      Map.new(names, fn name ->
        op = Map.fetch!(def_of, name)

        ins =
          op
          |> Pass.operand_values()
          |> Enum.map(&Pass.ref_name/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(&Map.has_key?(def_of, &1))
          |> Enum.uniq()
          |> Enum.reject(&(&1 == name))

        {name, ins}
      end)

    indeg = Map.new(dep_lists, fn {name, ins} -> {name, length(ins)} end)

    dependents =
      Enum.reduce(dep_lists, %{}, fn {name, ins}, acc ->
        Enum.reduce(ins, acc, fn in_name, a ->
          Map.update(a, in_name, [name], &[name | &1])
        end)
      end)

    ready = for {name, 0} <- indeg, do: name
    kahn(ready, indeg, dependents, [])
  end

  defp kahn([], indeg, _dependents, acc) do
    leftover =
      indeg
      |> Enum.filter(fn {_n, d} -> d > 0 end)
      |> Enum.map(fn {n, _d} -> n end)
      |> Enum.sort()

    Enum.reverse(acc) ++ leftover
  end

  defp kahn([n | rest], indeg, dependents, acc) do
    {ready_more, indeg} =
      dependents
      |> Map.get(n, [])
      |> Enum.reduce({[], indeg}, fn m, {ready, ind} ->
        d = Map.fetch!(ind, m) - 1
        ind = Map.put(ind, m, d)
        if d == 0, do: {[m | ready], ind}, else: {ready, ind}
      end)

    kahn(rest ++ ready_more, indeg, dependents, [n | acc])
  end
end
