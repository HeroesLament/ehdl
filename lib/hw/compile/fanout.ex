defmodule Hw.Compile.Fanout do
  @moduledoc """
  Register replication for high-fanout selects (`fanout :sig, copies`).

  A 1-bit register used as an `if` condition over many wide registers ends
  up as one net driving hundreds of LUT inputs after synthesis, and on xc7
  with nextpnr router2 those nets decide whether a design routes (see the
  OpenOcuSync routability guide). Declaring

      fanout :ldsel, 4

  in a component splits the register's consumers over 4 identical copies,
  zero latency (every copy loads the same next value as the original), so
  each copy drives about a quarter of the load.

  ## What the pass does (after the design is flattened)

    1. Finds the `Reg` that drives the signal. Only registers can be
       replicated without adding latency; anything else is an error.
    2. Counts the load of every consumer op: a mux that uses the signal as
       a condition costs its output width (one LUT input per output bit),
       any other use costs one.
    3. Splits a mux whose load is larger than one copy's share into
       bit-slices (`Slice` the values, one mux per slice, `Concat` back),
       so even a single 160-bit select spreads over the copies.
    4. Assigns consumers to copies, largest first, each to the copy with
       the least load so far, and renames the signal inside each op.
    5. Adds the copies as `Reg` ops with `keep: true`, same input, clock
       and reset as the original, and marks the original `keep: true` as
       well (otherwise opt_merge folds it into one of the copies).

  The IR stays plain registers, so `Hw.Sim` simulates the copies like any
  other register. The Verilog emitter writes each copy as a private `reg`
  in its own `(* keep *) always` block, the original included. Plain `reg` copies do not survive
  yosys: `opt_merge` merges flip-flops with the same D and init even when
  the reg is marked `(* keep *)`; the attribute on the `always` block
  lands on the flip-flop cell, which opt_merge leaves alone. No vendor
  cells, so the same Verilog works for every yosys target and iverilog
  (probe 2026-10-27 on generic, xc7, ecp5, ice40, gowin: 4 copies kept,
  max LUT-input fanout 128 -> 32, netlist sim matches RTL).

  ## Limits (v1)

    * 1-bit registers only, posedge clock, no async reset.
    * 2 to 64 copies.
  """

  alias Hw.IR.Design
  alias Hw.IR.Ops.{Concat, Mux, Reg, Slice}
  alias Hw.IR.Types.{Const, Signal}

  import Bitwise

  defmodule Error do
    defexception [:message]
  end

  @max_copies 64

  # ── requests ────────────────────────────────────────────────────────

  @doc """
  Record a module's `fanout` requests on the design, resolving each signal
  name through `signal_map` (the child's prefixed map when called from
  instance elaboration). Applied later by `apply/1`.
  """
  @spec mark(Design.t(), module(), map()) :: Design.t()
  def mark(%Design{} = design, module, signal_map) do
    requests =
      if Code.ensure_loaded?(module) and function_exported?(module, :__hw_fanouts__, 0),
        do: module.__hw_fanouts__(),
        else: []

    Enum.reduce(requests, design, fn %{signal: name, copies: n} = req, d ->
      case Map.get(signal_map, name) do
        %Signal{} = s ->
          entry = %{signal: s, copies: n, module: module, source_location: Map.get(req, :source_location)}
          %{d | fanouts: Map.get(d, :fanouts, []) ++ [entry]}

        _ ->
          raise Error, "fanout :#{name} in #{inspect(module)}: no such signal"
      end
    end)
  end

  @doc "Lower every recorded request. Clears `design.fanouts`."
  @spec apply(Design.t()) :: Design.t()
  def apply(%Design{} = design) do
    requests = Map.get(design, :fanouts, [])
    design = %{design | fanouts: []}
    Enum.reduce(requests, design, &replicate(&2, &1))
  end

  # ── one request ─────────────────────────────────────────────────────

  defp replicate(design, %{signal: %Signal{name: name}, copies: n, module: module}) do
    where = "fanout :#{name} in #{inspect(module)}"

    reg =
      Enum.find(design.ops, &match?(%Reg{output: %Signal{name: ^name}}, &1)) ||
        raise Error, "#{where}: :#{name} is not a register (assign it in an `on` block)"

    validate!(reg, n, where)

    copies =
      for k <- 1..(n - 1) do
        %{reg.output | name: :"#{name}__f#{k}", direction: :internal}
      end

    all = [reg.output | copies]

    {consumers, others} =
      Enum.split_with(design.ops, fn op -> op != reg and references?(op, name) end)

    units = consumers |> Enum.flat_map(&units(&1, name, n, consumers)) |> Enum.sort_by(&(-&1.load))

    {assigned, _loads} =
      Enum.map_reduce(units, Map.new(0..(n - 1), &{&1, 0}), fn unit, loads ->
        {k, _} = Enum.min_by(loads, fn {k, l} -> {l, k} end)
        {{unit, Enum.at(all, k)}, Map.update!(loads, k, &(&1 + unit.load))}
      end)

    {new_ops, new_signals} = rewrite(assigned, name)

    # The original is kept too: opt_merge would otherwise fold it into one
    # of the kept copies (probe 2026-10-27: 3 FFs left for 4, one at 2x load).
    kept = %{reg | keep: true}
    copy_regs = for c <- copies, do: %{reg | output: c, keep: true}
    others = Enum.map(others, &if(&1 == reg, do: kept, else: &1))

    design = %{design | ops: others ++ new_ops ++ copy_regs}
    Enum.reduce(copies ++ new_signals, design, &Design.add_signal(&2, &1))
  end

  defp validate!(%Reg{output: out, clock: clock, async_reset: ar}, n, where) do
    cond do
      not is_integer(n) or n < 2 or n > @max_copies ->
        raise Error, "#{where}: copies must be 2..#{@max_copies}, got #{inspect(n)}"

      out.width != 1 ->
        raise Error, "#{where}: only 1-bit registers can be replicated (width #{out.width})"

      ar != nil ->
        raise Error, "#{where}: registers with an async reset cannot be replicated"

      Map.get(clock, :edge, :posedge) != :posedge ->
        raise Error, "#{where}: only posedge registers can be replicated"

      true ->
        :ok
    end
  end

  # ── load units ──────────────────────────────────────────────────────

  # A unit is either a whole op, or one bit-slice of a wide mux whose
  # condition is the replicated signal.
  defp units(%Mux{output: out} = mux, name, n, consumers) do
    w = width(out)

    if condition?(mux, name) and w > 1 do
      share = share(consumers, name, n)

      if w > share do
        parts = div(w + share - 1, share)
        size = div(w + parts - 1, parts)

        for lo <- 0..(w - 1)//size do
          hi = min(lo + size - 1, w - 1)
          %{op: mux, slice: {hi, lo}, load: hi - lo + 1}
        end
      else
        [%{op: mux, slice: nil, load: w}]
      end
    else
      [%{op: mux, slice: nil, load: 1}]
    end
  end

  defp units(op, _name, _n, _consumers), do: [%{op: op, slice: nil, load: 1}]

  defp share(consumers, name, n) do
    total =
      consumers
      |> Enum.map(fn
        %Mux{output: out} = m -> if condition?(m, name), do: max(width(out), 1), else: 1
        _ -> 1
      end)
      |> Enum.sum()

    max(div(total + n - 1, n), 1)
  end

  defp condition?(%Mux{cases: cases}, name) do
    Enum.any?(cases, &match?({%Signal{name: ^name}, _}, &1))
  end

  # ── rewriting ───────────────────────────────────────────────────────

  # Whole ops: rename inside the op. Sliced muxes: one mux per slice, then
  # one Concat (MSB first) back onto the original output.
  defp rewrite(assigned, name) do
    {whole, sliced} = Enum.split_with(assigned, fn {u, _c} -> u.slice == nil end)

    whole_ops = for {u, copy} <- whole, do: rename(u.op, name, copy)

    {sliced_ops, sliced_signals} =
      sliced
      |> Enum.group_by(fn {u, _c} -> u.op end)
      |> Enum.reduce({[], []}, fn {mux, parts}, {ops, sigs} ->
        {o, s} = split_mux(mux, parts, name)
        {ops ++ o, sigs ++ s}
      end)

    {whole_ops ++ sliced_ops, sliced_signals}
  end

  defp split_mux(%Mux{output: out} = mux, parts, name) do
    parts = Enum.sort_by(parts, fn {u, _c} -> -elem(u.slice, 1) end)

    {ops, sigs, outs} =
      Enum.reduce(parts, {[], [], []}, fn {%{slice: {hi, lo}}, copy}, {ops, sigs, outs} ->
        tag = "#{out.name}__p#{lo}"
        part_out = %{out | name: :"#{tag}", width: hi - lo + 1, direction: :internal, init: nil}

        {cases, case_ops, case_sigs} =
          mux.cases
          |> Enum.with_index()
          |> Enum.reduce({[], [], []}, fn {{c, v}, i}, {cs, os, ss} ->
            {v2, o2, s2} = slice_value(v, hi, lo, "#{tag}_c#{i}")
            {cs ++ [{rename_value(c, name, copy), v2}], os ++ o2, ss ++ s2}
          end)

        {d2, d_ops, d_sigs} = slice_value(mux.default, hi, lo, "#{tag}_d")

        part = %Mux{
          mux
          | output: part_out,
            cases: cases,
            default: d2,
            selector: rename_value(mux.selector, name, copy)
        }

        {ops ++ case_ops ++ d_ops ++ [part], sigs ++ case_sigs ++ d_sigs ++ [part_out], outs ++ [part_out]}
      end)

    {ops ++ [%Concat{output: out, inputs: outs}], sigs}
  end

  defp slice_value(%Const{value: v, signed: s}, hi, lo, _tag) do
    w = hi - lo + 1
    {%Const{value: band(bsr(v, lo), (1 <<< w) - 1), width: w, signed: s}, [], []}
  end

  defp slice_value(%Signal{width: sw} = sig, hi, lo, tag) when is_integer(sw) and sw > hi do
    out = %Signal{sig | name: :"#{tag}", width: hi - lo + 1, direction: :internal, init: nil}
    hi_c = %Const{value: hi, width: 32, signed: :unsigned}
    lo_c = %Const{value: lo, width: 32, signed: :unsigned}
    {out, [%Slice{output: out, input: sig, hi: hi_c, lo: lo_c}], [out]}
  end

  defp slice_value(other, _hi, _lo, _tag) do
    raise Error, "fanout: cannot slice mux value #{inspect(other)}"
  end

  defp rename(op, name, %Signal{name: name}), do: op

  defp rename(%Mux{} = m, name, copy) do
    %Mux{
      m
      | cases: Enum.map(m.cases, fn {c, v} -> {rename_value(c, name, copy), rename_value(v, name, copy)} end),
        default: rename_value(m.default, name, copy),
        selector: rename_value(m.selector, name, copy)
    }
  end

  defp rename(op, name, copy) do
    op
    |> Map.from_struct()
    |> Enum.reduce(op, fn
      {k, _v}, acc when k in [:output, :output_re, :output_im, :clock, :__struct__] ->
        acc

      {k, v}, acc ->
        Map.put(acc, k, rename_value(v, name, copy))
    end)
  end

  defp rename_value(%Signal{name: name}, name, copy), do: copy
  defp rename_value(list, name, copy) when is_list(list), do: Enum.map(list, &rename_value(&1, name, copy))
  defp rename_value({a, b}, name, copy), do: {rename_value(a, name, copy), rename_value(b, name, copy)}
  defp rename_value(other, _name, _copy), do: other

  defp references?(op, name) do
    op
    |> Map.from_struct()
    |> Enum.any?(fn
      {k, _} when k in [:output, :output_re, :output_im, :clock] -> false
      {_k, v} -> mentions?(v, name)
    end)
  end

  defp mentions?(%Signal{name: name}, name), do: true
  defp mentions?(list, name) when is_list(list), do: Enum.any?(list, &mentions?(&1, name))
  defp mentions?({a, b}, name), do: mentions?(a, name) or mentions?(b, name)
  defp mentions?(_, _), do: false

  defp width(%Signal{width: w}) when is_integer(w), do: w
  defp width(%Const{width: w}) when is_integer(w), do: w
  defp width(_), do: 0
end
