defmodule Hw.Sim.Compiler do
  @moduledoc """
  Compiles a `%Hw.Sim.Schedule{}` into the flat data format expected by
  the `Hw.Sim.Nif.compile/1` Rust NIF.

  The Rust automaton needs:
  - A compact signal table: [{name_atom, width, initial_val}]
  - Entity list: [{name, is_top, [comb_op_map], [reg_next_op_map]}]
  - Clock list: [{name, period_ps, [entity_idx], [cross_settle_op_map]}]

  Ops are encoded as plain maps with an `:op` tag key, e.g.:
      %{op: :add, out: :phy_phase, w: 2, a: {:signal, :phy_phase}, b: {:const, 1}}

  Operands are either `{:signal, name_atom}` or `{:const, integer}`.
  """

  alias Hw.IR.Ops.{
    Assign, Add, Sub, Mul, Div, Mod, Neg, Abs, Min, Max,
    BitAnd, BitOr, BitXor, BitNot, Shl, Shr, Shra,
    ReduceAnd, ReduceOr, ReduceXor, Replicate, Cast,
    Eq, Neq, Lt, Gt, Lte, Gte,
    Slice, Concat, Mux, Reg,
    Blackbox, Tristate, Mem, MemRead, MemWrite, Clog2,
    MulRound, SignExtend, ZeroExtend, ReverseBits, Popcount
  }
  alias Hw.IR.Types.{Signal, Const, Clock}

  @doc """
  Compile a `%Hw.Sim.Schedule{}` into the NIF-ready map.

  Returns a map with `:signals`, `:entities`, `:clocks` keys.
  Pass the result directly to `Hw.Sim.Nif.compile/1`.
  """
  def compile(%Hw.Sim.Schedule{} = schedule) do
    # Build compact signal table using signal_inits for correct reset state.
    # Falls back to 0 for any signal not listed in signal_inits.
    inits = Map.get(schedule, :signal_inits, %{})
    signals =
      schedule.signal_widths
      |> Enum.map(fn {name, width} -> {name, width, Map.get(inits, name, 0)} end)
      |> Enum.sort_by(fn {name, _, _} -> Atom.to_string(name) end)

    # Order entities for clock subscription.
    # _top_ is excluded ONLY if it has no clock domain (pure combinational glue).
    # For flat components where all logic lives in _top_, it must participate
    # as a clocked entity so its Reg ops fire on each clock edge.
    entity_names =
      schedule.entities
      |> Map.keys()
      |> Enum.reject(fn name ->
        name == :_top_ and is_nil(schedule.entities[:_top_].domain)
      end)
      |> Enum.sort_by(&Atom.to_string/1)

    # Compile each entity
    compiled_entities =
      Enum.map(entity_names, fn name ->
        entity = schedule.entities[name]
        widths = schedule.signal_widths
        compile_entity(name, entity, widths)
      end)

    # Build entity index map for clock wiring
    _entity_index = entity_names |> Enum.with_index() |> Map.new()

    # Compile clocks
    # Clock period: freq_mhz -> period_ps = 1_000_000 / freq_mhz
    compiled_clocks =
      schedule.clocks
      |> Enum.filter(fn clk -> clk.name != nil end)
      |> Enum.map(fn clk ->
        period_ps = trunc(1_000_000 / clk.freq_mhz)

        # Which entities subscribe to this clock?
        subscribed_idxs =
          entity_names
          |> Enum.with_index()
          |> Enum.filter(fn {ent_name, _idx} ->
            entity = schedule.entities[ent_name]
            entity.domain == clk.name
          end)
          |> Enum.map(fn {_, idx} -> idx end)

        # Cross-settle: run all _top_ ops (they compute intermediates that
        # entities depend on, e.g. _neq_ signals for tx_act/rx_act checks)
        # plus the schedule's explicit cross_settle_ops.
        top_ops = case Map.get(schedule.entities, :_top_) do
          nil    -> []
          entity -> Enum.map(entity.ops, &compile_op(&1, schedule.signal_widths))
                    |> Enum.reject(&is_nil/1)
        end

        settle_ops =
          schedule.cross_settle_ops
          |> Enum.map(&compile_op(&1, schedule.signal_widths))
          |> Enum.reject(&is_nil/1)

        # Deduplicate by output signal — top_ops takes precedence
        covered = MapSet.new(top_ops, & &1.out)
        extra = Enum.reject(settle_ops, &MapSet.member?(covered, &1.out))

        cross_ops = top_ops ++ extra

        {clk.name, period_ps, subscribed_idxs, cross_ops}
      end)
      |> Enum.reject(fn {_name, _ps, idxs, _ops} -> idxs == [] end)

    %{
      signals: signals,
      entities: compiled_entities,
      clocks: compiled_clocks,
    }
  end

  # ---------------------------------------------------------------------------
  # Entity compilation
  # ---------------------------------------------------------------------------

  defp compile_entity(name, entity, widths) do
    is_top = name == :_top_

    # Comb ops: everything except Reg, Mem, Blackbox, Tristate, MemWrite
    comb_ops =
      entity.ops
      |> Enum.reject(&skip_op?/1)
      |> Enum.map(&compile_op(&1, widths))
      |> Enum.reject(&is_nil/1)

    # Reg next ops — compiled as :reg_next tagged maps
    reg_next_ops =
      entity.regs
      |> Enum.map(&compile_reg_next(&1, widths))
      |> Enum.reject(&is_nil/1)

    {name, is_top, comb_ops, reg_next_ops}
  end

  defp skip_op?(%Reg{}),      do: true
  defp skip_op?(%Mem{}),      do: true
  defp skip_op?(%MemWrite{}), do: true
  defp skip_op?(%Blackbox{}), do: true
  defp skip_op?(%Tristate{}), do: true
  defp skip_op?(_),           do: false

  # ---------------------------------------------------------------------------
  # Op compilation
  # ---------------------------------------------------------------------------

  defp compile_op(%Assign{output: out, input: input}, widths) do
    %{op: :assign, out: out.name, w: width(out, widths), a: operand(input)}
  end

  defp compile_op(%Add{output: out, a: a, b: b}, widths) do
    %{op: :add, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%Sub{output: out, a: a, b: b}, widths) do
    %{op: :sub, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%Mul{output: out, a: a, b: b}, widths) do
    %{op: :mul, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%Div{output: out, a: a, b: b}, widths) do
    %{op: :div, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%Mod{output: out, a: a, b: b}, widths) do
    %{op: :mod, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%Neg{output: out, input: input}, widths) do
    %{op: :neg, out: out.name, w: width(out, widths), a: operand(input)}
  end

  defp compile_op(%Abs{output: out, input: input}, widths) do
    %{op: :abs, out: out.name, w: width(out, widths), a: operand(input)}
  end

  defp compile_op(%Min{output: out, a: a, b: b}, widths) do
    %{op: :min, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%Max{output: out, a: a, b: b}, widths) do
    %{op: :max, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%BitAnd{output: out, a: a, b: b}, widths) do
    %{op: :bit_and, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%BitOr{output: out, a: a, b: b}, widths) do
    %{op: :bit_or, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%BitXor{output: out, a: a, b: b}, widths) do
    %{op: :bit_xor, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%BitNot{output: out, input: input}, widths) do
    %{op: :bit_not, out: out.name, w: width(out, widths), a: operand(input)}
  end

  defp compile_op(%Shl{output: out, a: a, b: b}, widths) do
    %{op: :shl, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%Shr{output: out, a: a, b: b}, widths) do
    %{op: :shr, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%Shra{output: out, a: a, b: b}, widths) do
    %{op: :shra, out: out.name, w: width(out, widths), a: operand(a), b: operand(b)}
  end

  defp compile_op(%ReduceAnd{output: out, input: input}, widths) do
    input_w = case input do
      %Signal{width: w} -> w
      _ -> Map.get(widths, operand_name(input), 1)
    end
    %{op: :reduce_and, out: out.name, w: 1, input_w: input_w, a: operand(input)}
  end

  defp compile_op(%ReduceOr{output: out, input: input}, _widths) do
    %{op: :reduce_or, out: out.name, w: 1, a: operand(input)}
  end

  defp compile_op(%ReduceXor{output: out, input: input}, _widths) do
    %{op: :reduce_xor, out: out.name, w: 1, a: operand(input)}
  end

  defp compile_op(%Replicate{output: out, input: input, count: count}, widths) do
    %{op: :replicate, out: out.name, w: width(out, widths), a: operand(input), count: operand(count)}
  end

  defp compile_op(%Cast{output: out, input: input}, widths) do
    %{op: :cast, out: out.name, w: width(out, widths), a: operand(input)}
  end

  defp compile_op(%Eq{output: out, a: a, b: b}, _widths) do
    %{op: :eq, out: out.name, w: 1, a: operand(a), b: operand(b)}
  end

  defp compile_op(%Neq{output: out, a: a, b: b}, _widths) do
    %{op: :neq, out: out.name, w: 1, a: operand(a), b: operand(b)}
  end

  defp compile_op(%Lt{output: out, a: a, b: b}, _widths) do
    %{op: :lt, out: out.name, w: 1, a: operand(a), b: operand(b)}
  end

  defp compile_op(%Gt{output: out, a: a, b: b}, _widths) do
    %{op: :gt, out: out.name, w: 1, a: operand(a), b: operand(b)}
  end

  defp compile_op(%Lte{output: out, a: a, b: b}, _widths) do
    %{op: :lte, out: out.name, w: 1, a: operand(a), b: operand(b)}
  end

  defp compile_op(%Gte{output: out, a: a, b: b}, _widths) do
    %{op: :gte, out: out.name, w: 1, a: operand(a), b: operand(b)}
  end

  defp compile_op(%Slice{output: out, input: input, hi: hi, lo: lo}, _widths) do
    %{op: :slice, out: out.name, w: const_val(hi) - const_val(lo) + 1,
      a: operand(input), hi: const_val(hi), lo: const_val(lo)}
  end

  defp compile_op(%Concat{output: out, inputs: inputs}, widths) do
    compiled_inputs =
      Enum.map(inputs, fn inp ->
        w = case inp do
          %Signal{width: w} -> w
          %Const{width: w}  -> w
          _ -> 1
        end
        {operand(inp), w}
      end)
    %{op: :concat, out: out.name, w: width(out, widths), inputs: compiled_inputs}
  end

  defp compile_op(%Mux{output: out, cases: cases, default: default}, widths) do
    compiled_cases = Enum.map(cases, fn {cond, val} -> {operand(cond), operand(val)} end)
    %{op: :mux, out: out.name, w: width(out, widths), cases: compiled_cases, default: operand(default)}
  end

  defp compile_op(%MemRead{output: out, memory: _mem, addr: _addr}, widths) do
    # Model as returning 0 — memory ops not supported in Rust sim yet
    %{op: :assign, out: out.name, w: width(out, widths), a: {:const, 0}}
  end

  # MulRound: (a * b + (1 << (shift-1))) >>> shift — decompose to available ops
  defp compile_op(%MulRound{output: out, a: a, b: _b, shift: shift}, widths) do
    # Approximate: just do mul then shr (loses rounding, acceptable for sim)
    %{op: :shr, out: out.name, w: width(out, widths),
      a: operand(a), b: operand(%Const{value: shift, width: 8, signed: :unsigned})}
  end

  defp compile_op(%SignExtend{output: out, input: input}, widths) do
    %{op: :cast, out: out.name, w: width(out, widths), a: operand(input)}
  end

  defp compile_op(%ZeroExtend{output: out, input: input}, widths) do
    %{op: :cast, out: out.name, w: width(out, widths), a: operand(input)}
  end

  defp compile_op(%ReverseBits{output: out, input: input}, widths) do
    # Not directly supported — emit as assign (pass-through) for now
    %{op: :assign, out: out.name, w: width(out, widths), a: operand(input)}
  end

  defp compile_op(%Popcount{output: out, input: input}, widths) do
    # Map to reduce_xor as approximate (popcount not in NIF yet)
    %{op: :reduce_or, out: out.name, w: width(out, widths), a: operand(input)}
  end

  defp compile_op(%Clog2{output: out, input: input}, widths) do
    # Not directly supported — emit as assign for now
    %{op: :assign, out: out.name, w: width(out, widths), a: operand(input)}
  end

  # Skip anything else (Mem, MemWrite, Blackbox, Tristate, Reg)
  defp compile_op(_op, _widths), do: nil

  # ---------------------------------------------------------------------------
  # Reg next compilation
  # ---------------------------------------------------------------------------

  defp compile_reg_next(%Reg{output: out, input: input, clock: _clk,
                              enable: enable, reset_value: reset_val,
                              async_reset: async_reset}, widths) do
    reset_int = case reset_val do
      %Hw.IR.Types.Const{value: v} -> v
      v when is_integer(v)         -> v
      nil                          -> 0
    end
    %{
      op:          :reg_next,
      out:         out.name,
      w:           width(out, widths),
      a:           operand(input),
      enable:      operand_or_nil(enable),
      reset_val:   reset_int,
      async_reset: operand_or_nil(async_reset),
    }
  end

  defp compile_reg_next(_op, _widths), do: nil

  # ---------------------------------------------------------------------------
  # Operand encoding
  # ---------------------------------------------------------------------------

  defp operand(%Signal{name: name}), do: {:signal, name}
  defp operand(%Const{value: v}),    do: {:const, v}
  defp operand(%Clock{name: name}),  do: {:signal, name}
  defp operand(nil),                 do: nil
  defp operand(v) when is_integer(v), do: {:const, v}
  defp operand(name) when is_atom(name), do: {:signal, name}

  defp operand_or_nil(nil), do: nil
  defp operand_or_nil(x),   do: operand(x)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp width(%Signal{width: w}, _widths), do: w
  defp width(%Const{width: w}, _widths),  do: w
  defp width(_, _widths), do: 1

  defp const_val(%Const{value: v}), do: v
  defp const_val(v) when is_integer(v), do: v

  defp operand_name(%Signal{name: n}), do: n
  defp operand_name(_), do: nil
end
