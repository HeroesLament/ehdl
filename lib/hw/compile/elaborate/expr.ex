defmodule Hw.Compile.Elaborate.Expr do
  @moduledoc """
  Expression building for elaboration.

  Converts DSL expression AST into IR ops.
  """

  alias Hw.IR.Design
  alias Hw.IR.Types.{Signal, Const, ParamRef}
  alias Hw.IR.Ops

  @doc """
  Build an expression, returning {value, updated_design}.

  Expressions may create intermediate signals and ops as side effects.
  """
  # Instance signal access: cnt.count -> lookup in instance_map
  def build_expr({:instance_signal, inst_name, sig_name}, _signal_map, instance_map, _memory_map, design) do
    case Map.get(instance_map, inst_name) do
      nil ->
        raise Hw.Compile.Elaborate.ElabError, message: "Unknown instance: #{inst_name}", context: {inst_name, sig_name}
      inst_signals ->
        case Map.get(inst_signals, sig_name) do
          nil ->
            raise Hw.Compile.Elaborate.ElabError, message: "Unknown signal #{sig_name} on instance #{inst_name}", context: {inst_name, sig_name}
          signal ->
            {signal, design}
        end
    end
  end

  # Signal reference - first try signals, then params
  def build_expr({:signal, name}, signal_map, _instance_map, _memory_map, design) do
    case Map.get(signal_map, name) do
      nil ->
        # Try params — fall back to symbolic ParamRef for Verilog emission
        case Enum.find(design.params, &(&1.name == name)) do
          nil ->
            raise Hw.Compile.Elaborate.ElabError,
              message: "Unknown signal or parameter: #{name}", context: name
          _param ->
            {%ParamRef{name: name}, design}
        end
      signal ->
        {signal, design}
    end
  end

  def build_expr({:const, n}, _signal_map, _instance_map, _memory_map, design) do
    {%Const{value: n, width: 32, signed: :unsigned}, design}
  end

  # High-Z constant for tri-state
  def build_expr({:const_z}, _signal_map, _instance_map, _memory_map, design) do
    {%Const{value: :z, width: 1, signed: :unsigned}, design}
  end

  # Memory read: mem[addr] - could be memory or signal bit index
  def build_expr({:mem_or_index, name, addr_expr}, signal_map, instance_map, memory_map, design) do
    case Map.get(memory_map, name) do
      %Ops.Mem{sync_read: sync_read} = mem ->
        {addr_val, d1} = build_expr(addr_expr, signal_map, instance_map, memory_map, design)

        # Determine if sync read and get clock.
        #
        # sync_read may be:
        #   false/nil        -> async (combinational) read, clock = nil
        #   true             -> registered read on the design's clock. This is
        #                       the common case (`memory ..., sync_read: true`).
        #                       `true` is an atom, so it MUST be handled BEFORE
        #                       the generic `is_atom` clause below or it would be
        #                       treated as a clock NAME, `Enum.find` would fail
        #                       to match any clock, and the read would silently
        #                       degrade to async (-> uninitializable ECP5 LUT-RAM,
        #                       reading zeros on silicon). This bug shipped once.
        #   an atom clk name -> registered read on that specific named clock
        clock = case sync_read do
          b when b in [false, nil] -> nil
          true ->
            case d1.clocks do
              [only_clock] -> only_clock
              [first_clock | _] -> first_clock
              [] ->
                raise Hw.Compile.Elaborate.ElabError,
                  message: "memory #{mem.name} declared sync_read: true but the design has no clock to register the read on",
                  context: mem.name
            end
          clock_name when is_atom(clock_name) ->
            case Enum.find(d1.clocks, &(&1.name == clock_name)) do
              nil ->
                raise Hw.Compile.Elaborate.ElabError,
                  message: "memory #{mem.name} declared sync_read: #{inspect(clock_name)} but no clock named #{inspect(clock_name)} exists in the design",
                  context: mem.name
              clk -> clk
            end
        end

        result_name = :"_memrd_#{:erlang.unique_integer([:positive])}"
        result_sig = %Signal{name: result_name, width: mem.width, signed: :unsigned, direction: :internal}
        d2 = Design.add_signal(d1, result_sig)

        read_op = %Ops.MemRead{
          output: result_sig,
          memory: mem.name,
          addr: addr_val,
          clock: clock
        }
        d3 = Design.add_op(d2, read_op)

        {result_sig, d3}

      nil ->
        # It's a signal bit index
        signal = Map.fetch!(signal_map, name)
        {_addr_val, d1} = build_expr(addr_expr, signal_map, instance_map, memory_map, design)
        {signal, d1}
    end
  end

  # --- Arithmetic ---

  def build_expr({:add, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)
    {a_val, b_val} = match_const_widths(a_val, b_val)

    result_name = :"_add_#{:erlang.unique_integer([:positive])}"
    width = infer_width(a_val, b_val)
    signed = infer_signedness(a_val, b_val)
    # Both operands must be the result width (the validator requires equal-width
    # arithmetic operands). Zero-extend the narrower one instead of letting a
    # width-mismatch escape — e.g. `0x30`(6-bit) + `addr_hi`(4-bit).
    {a_val, d2a} = align_to_width(a_val, width, d2)
    {b_val, d2b} = align_to_width(b_val, width, d2a)

    result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}
    d3 = Design.add_signal(d2b, result_sig)
    d4 = Design.add_op(d3, %Ops.Add{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:sub, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    case {a_val, b_val} do
      {%Const{value: av}, %Const{value: bv}} ->
        {%Const{value: av - bv, width: 32, signed: :unsigned}, d2}
      _ ->
        {a_val, b_val} = match_const_widths(a_val, b_val)
        result_name = :"_sub_#{:erlang.unique_integer([:positive])}"
        width = infer_width(a_val, b_val)
        signed = infer_signedness(a_val, b_val)
        {a_val, d2a} = align_to_width(a_val, width, d2)
        {b_val, d2b} = align_to_width(b_val, width, d2a)
        result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}
        d3 = Design.add_signal(d2b, result_sig)
        d4 = Design.add_op(d3, %Ops.Sub{output: result_sig, a: a_val, b: b_val})
        {result_sig, d4}
    end
  end

  def build_expr({:mul, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    case {a_val, b_val} do
      {%Const{value: av}, %Const{value: bv}} ->
        {%Const{value: av * bv, width: 32, signed: :unsigned}, d2}
      _ ->
        {a_val, b_val} = match_const_widths(a_val, b_val)
        result_name = :"_mul_#{:erlang.unique_integer([:positive])}"
        width = infer_width(a_val, b_val)
        signed = infer_signedness(a_val, b_val)
        result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}
        d3 = Design.add_signal(d2, result_sig)
        d4 = Design.add_op(d3, %Ops.Mul{output: result_sig, a: a_val, b: b_val})
        {result_sig, d4}
    end
  end

  # --- Bitwise ---

  def build_expr({:band, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_band_#{:erlang.unique_integer([:positive])}"
    width = infer_width(a_val, b_val)

    result_sig = %Signal{name: result_name, width: width, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.BitAnd{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:bor, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_bor_#{:erlang.unique_integer([:positive])}"
    width = infer_width(a_val, b_val)

    result_sig = %Signal{name: result_name, width: width, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.BitOr{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:bnot, a}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    result_name = :"_bnot_#{:erlang.unique_integer([:positive])}"
    width = case a_val do
      %Signal{width: w} -> w
      %Const{width: w} -> w
    end

    result_sig = %Signal{name: result_name, width: width, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.BitNot{output: result_sig, input: a_val})

    {result_sig, d3}
  end

  def build_expr({:bxor, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_xor_#{:erlang.unique_integer([:positive])}"
    width = infer_width(a_val, b_val)

    result_sig = %Signal{name: result_name, width: width, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.BitXor{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:shl, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_shl_#{:erlang.unique_integer([:positive])}"
    width = infer_width(a_val, b_val)

    result_sig = %Signal{name: result_name, width: width, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Shl{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:shr, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_shr_#{:erlang.unique_integer([:positive])}"
    width = infer_width(a_val, b_val)
    signed = infer_signedness(a_val, b_val)

    result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Shr{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  # Arithmetic shift right (sign-extending)
  def build_expr({:shra, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_shra_#{:erlang.unique_integer([:positive])}"
    width = infer_width(a_val, b_val)

    result_sig = %Signal{name: result_name, width: width, signed: :signed, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Shra{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  # --- Comparisons ---

  def build_expr({:eq, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_eq_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Eq{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:neq, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_neq_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Neq{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:lt, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_lt_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Lt{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:gt, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_gt_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Gt{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:lte, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_lte_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Lte{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:gte, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_gte_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Gte{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  # --- Logical (for conditions) ---

  def build_expr({:land, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_land_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.BitAnd{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:lor, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    result_name = :"_lor_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.BitOr{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:lnot, a}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    result_name = :"_lnot_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.BitNot{output: result_sig, input: a_val})

    {result_sig, d3}
  end

  # --- Bit manipulation ---

  def build_expr({:slice, base, hi, lo}, signal_map, instance_map, memory_map, design) do
    {base_val, d1} = build_expr(base, signal_map, instance_map, memory_map, design)
    {hi_val, d2} = build_expr(hi, signal_map, instance_map, memory_map, d1)
    {lo_val, d3} = build_expr(lo, signal_map, instance_map, memory_map, d2)

    width = case {hi_val, lo_val} do
      {%Const{value: h}, %Const{value: l}} -> h - l + 1
      _ -> 8  # Fallback for dynamic slices
    end

    result_name = :"_slice_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: width, signed: :unsigned, direction: :internal}
    d4 = Design.add_signal(d3, result_sig)
    d5 = Design.add_op(d4, %Ops.Slice{output: result_sig, input: base_val, hi: hi_val, lo: lo_val})

    {result_sig, d5}
  end

  def build_expr({:concat, elements}, signal_map, instance_map, memory_map, design) do
    {vals, d1} = Enum.reduce(elements, {[], design}, fn elem, {acc, d} ->
      {val, d2} = build_expr(elem, signal_map, instance_map, memory_map, d)
      {[val | acc], d2}
    end)
    vals = Enum.reverse(vals)

    width = Enum.reduce(vals, 0, fn
      %Signal{width: w}, acc -> acc + w
      %Const{width: w}, acc -> acc + w
    end)

    result_name = :"_cat_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: width, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.Concat{output: result_sig, inputs: vals})

    {result_sig, d3}
  end

  # --- New arithmetic ops ---

  def build_expr({:neg, a}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    result_name = :"_neg_#{:erlang.unique_integer([:positive])}"
    width = case a_val do
      %Signal{width: w} -> w
      %Const{width: w} -> w
    end

    result_sig = %Signal{name: result_name, width: width, signed: :signed, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.Neg{output: result_sig, input: a_val})

    {result_sig, d3}
  end

  def build_expr({:div, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    case {a_val, b_val} do
      {%Const{value: av}, %Const{value: bv}} when bv != 0 ->
        {%Const{value: div(av, bv), width: 32, signed: :unsigned}, d2}
      _ ->
        {a_val, b_val} = match_const_widths(a_val, b_val)
        result_name = :"_div_#{:erlang.unique_integer([:positive])}"
        width = infer_width(a_val, b_val)
        signed = infer_signedness(a_val, b_val)
        result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}
        d3 = Design.add_signal(d2, result_sig)
        d4 = Design.add_op(d3, %Ops.Div{output: result_sig, a: a_val, b: b_val})
        {result_sig, d4}
    end
  end

  def build_expr({:mod, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)
    {a_val, b_val} = match_const_widths(a_val, b_val)

    result_name = :"_mod_#{:erlang.unique_integer([:positive])}"
    width = infer_width(a_val, b_val)
    signed = infer_signedness(a_val, b_val)

    result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Mod{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  # --- Reduction ops ---

  def build_expr({:reduce_and, a}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    result_name = :"_rand_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.ReduceAnd{output: result_sig, input: a_val})

    {result_sig, d3}
  end

  def build_expr({:reduce_or, a}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    result_name = :"_ror_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.ReduceOr{output: result_sig, input: a_val})

    {result_sig, d3}
  end

  def build_expr({:reduce_xor, a}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    result_name = :"_rxor_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.ReduceXor{output: result_sig, input: a_val})

    {result_sig, d3}
  end

  # --- Popcount ---

  def build_expr({:popcount, a}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    input_width = case a_val do
      %Signal{width: w} -> w
      %Const{width: w} -> w
    end

    # Output width is clog2(input_width + 1)
    # E.g., 8-bit input can have 0-8 ones, needs 4 bits
    output_width = if input_width <= 1, do: 1, else: ceil(:math.log2(input_width + 1)) |> trunc()

    result_name = :"_popc_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: output_width, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.Popcount{output: result_sig, input: a_val})

    {result_sig, d3}
  end

  # --- Sign Extend ---

  def build_expr({:sign_extend, a, target_width}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    result_name = :"_sext_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: target_width, signed: :signed, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.SignExtend{output: result_sig, input: a_val, width: target_width})

    {result_sig, d3}
  end

  # --- Zero Extend ---

  def build_expr({:zero_extend, a, target_width}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    result_name = :"_zext_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: target_width, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.ZeroExtend{output: result_sig, input: a_val, width: target_width})

    {result_sig, d3}
  end

  # --- Reverse Bits ---

  def build_expr({:reverse_bits, a}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    width = case a_val do
      %Signal{width: w} -> w
      %Const{width: w} -> w
    end

    result_name = :"_rev_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: width, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.ReverseBits{output: result_sig, input: a_val})

    {result_sig, d3}
  end

  # --- Abs ---

  def build_expr({:abs, a}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    width = case a_val do
      %Signal{width: w} -> w
      %Const{width: w} -> w
    end

    result_name = :"_abs_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: width, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.Abs{output: result_sig, input: a_val})

    {result_sig, d3}
  end

  # --- clog2 ---

  def build_expr({:clog2, a}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    case a_val do
      %Const{value: v} ->
        # Constant - evaluate at compile time
        result = if v <= 1, do: 1, else: ceil(:math.log2(v)) |> trunc()
        {%Const{value: result, width: 32, signed: :unsigned}, d1}

      %ParamRef{} ->
        # Parameter - emit $clog2() for runtime evaluation
        result_name = :"_clog2_#{:erlang.unique_integer([:positive])}"
        result_sig = %Signal{name: result_name, width: 32, signed: :unsigned, direction: :internal}
        d2 = Design.add_signal(d1, result_sig)
        d3 = Design.add_op(d2, %Hw.IR.Ops.Clog2{output: result_sig, input: a_val})
        {result_sig, d3}

      _ ->
        raise Hw.Compile.Elaborate.ElabError,
          message: "clog2 can only be applied to constants or parameters",
          context: a_val
    end
  end

  # --- Min/Max ---

  def build_expr({:min, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    width = infer_width(a_val, b_val)
    signed = infer_signedness(a_val, b_val)

    result_name = :"_min_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Min{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  def build_expr({:max, a, b}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    width = infer_width(a_val, b_val)
    signed = infer_signedness(a_val, b_val)

    result_name = :"_max_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Ops.Max{output: result_sig, a: a_val, b: b_val})

    {result_sig, d4}
  end

  # --- mul_round: (a * b + round) >>> shift ---

  def build_expr({:mul_round, a, b, shift}, signal_map, instance_map, memory_map, design) when is_integer(shift) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)
    {b_val, d2} = build_expr(b, signal_map, instance_map, memory_map, d1)

    a_width = case a_val do
      %Signal{width: w} -> w
      %Const{width: w} -> w
    end
    b_width = case b_val do
      %Signal{width: w} -> w
      %Const{width: w} -> w
    end

    # Full product width, then we'll shift down
    product_width = a_width + b_width
    result_width = product_width - shift
    signed = infer_signedness(a_val, b_val)

    result_name = :"_mulr_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: result_width, signed: signed, direction: :internal}
    d3 = Design.add_signal(d2, result_sig)
    d4 = Design.add_op(d3, %Hw.IR.Ops.MulRound{output: result_sig, a: a_val, b: b_val, shift: shift})

    {result_sig, d4}
  end

  # --- Complex operations ---
  # These expand to _re/_im signal pairs

  def build_expr({:cmul, a_name, b_name}, signal_map, _instance_map, _memory_map, design) do
    # Look up the _re and _im signals for each complex
    a_re = Map.fetch!(signal_map, :"#{a_name}_re")
    a_im = Map.fetch!(signal_map, :"#{a_name}_im")
    b_re = Map.fetch!(signal_map, :"#{b_name}_re")
    b_im = Map.fetch!(signal_map, :"#{b_name}_im")

    width = a_re.width

    # Result signals
    result_re_name = :"_cmul_re_#{:erlang.unique_integer([:positive])}"
    result_im_name = :"_cmul_im_#{:erlang.unique_integer([:positive])}"
    result_re = %Signal{name: result_re_name, width: width, signed: :signed, direction: :internal}
    result_im = %Signal{name: result_im_name, width: width, signed: :signed, direction: :internal}

    d1 = Design.add_signal(design, result_re)
    d2 = Design.add_signal(d1, result_im)
    d3 = Design.add_op(d2, %Hw.IR.Ops.ComplexMul{
      output_re: result_re, output_im: result_im,
      a_re: a_re, a_im: a_im,
      b_re: b_re, b_im: b_im
    })

    # Return a tuple of the result signals
    {{result_re, result_im}, d3}
  end

  def build_expr({:cadd, a_name, b_name}, signal_map, _instance_map, _memory_map, design) do
    a_re = Map.fetch!(signal_map, :"#{a_name}_re")
    a_im = Map.fetch!(signal_map, :"#{a_name}_im")
    b_re = Map.fetch!(signal_map, :"#{b_name}_re")
    b_im = Map.fetch!(signal_map, :"#{b_name}_im")

    width = a_re.width

    result_re_name = :"_cadd_re_#{:erlang.unique_integer([:positive])}"
    result_im_name = :"_cadd_im_#{:erlang.unique_integer([:positive])}"
    result_re = %Signal{name: result_re_name, width: width, signed: :signed, direction: :internal}
    result_im = %Signal{name: result_im_name, width: width, signed: :signed, direction: :internal}

    d1 = Design.add_signal(design, result_re)
    d2 = Design.add_signal(d1, result_im)
    d3 = Design.add_op(d2, %Hw.IR.Ops.ComplexAdd{
      output_re: result_re, output_im: result_im,
      a_re: a_re, a_im: a_im,
      b_re: b_re, b_im: b_im
    })

    {{result_re, result_im}, d3}
  end

  def build_expr({:csub, a_name, b_name}, signal_map, _instance_map, _memory_map, design) do
    a_re = Map.fetch!(signal_map, :"#{a_name}_re")
    a_im = Map.fetch!(signal_map, :"#{a_name}_im")
    b_re = Map.fetch!(signal_map, :"#{b_name}_re")
    b_im = Map.fetch!(signal_map, :"#{b_name}_im")

    width = a_re.width

    result_re_name = :"_csub_re_#{:erlang.unique_integer([:positive])}"
    result_im_name = :"_csub_im_#{:erlang.unique_integer([:positive])}"
    result_re = %Signal{name: result_re_name, width: width, signed: :signed, direction: :internal}
    result_im = %Signal{name: result_im_name, width: width, signed: :signed, direction: :internal}

    d1 = Design.add_signal(design, result_re)
    d2 = Design.add_signal(d1, result_im)
    d3 = Design.add_op(d2, %Hw.IR.Ops.ComplexSub{
      output_re: result_re, output_im: result_im,
      a_re: a_re, a_im: a_im,
      b_re: b_re, b_im: b_im
    })

    {{result_re, result_im}, d3}
  end

  def build_expr({:cmag_sq, a_name}, signal_map, _instance_map, _memory_map, design) do
    a_re = Map.fetch!(signal_map, :"#{a_name}_re")
    a_im = Map.fetch!(signal_map, :"#{a_name}_im")

    # Magnitude squared is wider: 2*width + 1 for sum of squares
    width = a_re.width * 2 + 1

    result_name = :"_cmagsq_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: width, signed: :unsigned, direction: :internal}

    d1 = Design.add_signal(design, result_sig)
    d2 = Design.add_op(d1, %Hw.IR.Ops.ComplexMagSq{output: result_sig, a_re: a_re, a_im: a_im})

    {result_sig, d2}
  end

  def build_expr({:cconj, a_name}, signal_map, _instance_map, _memory_map, design) do
    a_re = Map.fetch!(signal_map, :"#{a_name}_re")
    a_im = Map.fetch!(signal_map, :"#{a_name}_im")

    width = a_re.width

    result_re_name = :"_cconj_re_#{:erlang.unique_integer([:positive])}"
    result_im_name = :"_cconj_im_#{:erlang.unique_integer([:positive])}"
    result_re = %Signal{name: result_re_name, width: width, signed: :signed, direction: :internal}
    result_im = %Signal{name: result_im_name, width: width, signed: :signed, direction: :internal}

    d1 = Design.add_signal(design, result_re)
    d2 = Design.add_signal(d1, result_im)
    d3 = Design.add_op(d2, %Hw.IR.Ops.ComplexConj{
      output_re: result_re, output_im: result_im,
      a_re: a_re, a_im: a_im
    })

    {{result_re, result_im}, d3}
  end

  # --- Replication ---

  def build_expr({:replicate, a, count}, signal_map, instance_map, memory_map, design) do
    {a_val, d1} = build_expr(a, signal_map, instance_map, memory_map, design)

    input_width = case a_val do
      %Signal{width: w} -> w
      %Const{width: w} -> w
    end

    result_name = :"_rep_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: input_width * count, signed: :unsigned, direction: :internal}
    d2 = Design.add_signal(d1, result_sig)
    d3 = Design.add_op(d2, %Ops.Replicate{output: result_sig, input: a_val, count: count})

    {result_sig, d3}
  end

  # --- Ternary expression: cond ? then : else ---

  def build_expr({:ternary, cond, then_val, else_val}, signal_map, instance_map, memory_map, design) do
    {cond_val, d1} = build_expr(cond, signal_map, instance_map, memory_map, design)
    {then_result, d2} = build_expr(then_val, signal_map, instance_map, memory_map, d1)
    {else_result, d3} = build_expr(else_val, signal_map, instance_map, memory_map, d2)

    # Result is as wide as the WIDER branch; the narrower branch is zero-extended
    # (Signal) or width-bumped (Const) so both mux arms are exactly `width`.
    # Using infer_width alone left a narrow arm mismatched against the output.
    width = infer_width(then_result, else_result)
    signed = infer_signedness(then_result, else_result)

    {then_result, d3a} = align_to_width(then_result, width, d3)
    {else_result, d3b} = align_to_width(else_result, width, d3a)

    result_name = :"_mux_#{:erlang.unique_integer([:positive])}"
    result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}
    d4 = Design.add_signal(d3b, result_sig)

    mux_op = %Ops.Mux{
      output: result_sig,
      cases: [{cond_val, then_result}],
      default: else_result
    }
    d5 = Design.add_op(d4, mux_op)

    {result_sig, d5}
  end

  # Zero-extend a value to `width` if it is a narrower Signal; widen a Const's
  # declared width in place (the emitter sizes the literal). Values already at
  # or above `width` pass through. Keeps arithmetic operands equal-width without
  # silent truncation, in dialect-neutral Verilog.
  def align_to_width(%Signal{width: w} = s, width, design) when w < width do
    name = :"_zext_#{:erlang.unique_integer([:positive])}"
    sig = %Signal{name: name, width: width, signed: :unsigned, direction: :internal}
    d1 = Design.add_signal(design, sig)
    d2 = Design.add_op(d1, %Ops.ZeroExtend{output: sig, input: s, width: width})
    {sig, d2}
  end
  def align_to_width(%Const{value: v} = c, width, design) when is_integer(v) do
    {%Const{c | width: width}, design}
  end
  def align_to_width(val, _width, design), do: {val, design}

  # Passthrough for already-built values
  def build_expr(%Signal{} = sig, _signal_map, _instance_map, _memory_map, design), do: {sig, design}
  def build_expr(%Const{} = c, _signal_map, _instance_map, _memory_map, design), do: {c, design}

  # Fallback
  def build_expr(other, _signal_map, _instance_map, _memory_map, _design) do
    raise Hw.Compile.Elaborate.ElabError,
      message: "Cannot elaborate expression: #{inspect(other, pretty: true, limit: 10)}",
      context: other
  end

  # --- Private Helpers ---

  defp match_value_to_width(%Const{} = c, width, signed), do: %Const{c | width: width, signed: signed}
  defp match_value_to_width(val, _width, _signed), do: val

  # --- Width/Signedness Inference ---
  #
  # Arithmetic/bitwise result width follows Verilog's self-determined-expression
  # rule: the result is as wide as the WIDEST operand, never the first operand.
  # Inferring from `a` alone silently truncated `0x30 + rx_state` (2-bit) to 2
  # bits, dropping the constant's high bits and emitting legal-but-wrong Verilog.
  def infer_width(a, b) do
    wa = value_width(a)
    wb = value_width(b)
    cond do
      wa != nil and wb != nil -> max(wa, wb)
      wa != nil               -> wa
      wb != nil               -> wb
      true                    -> 32
    end
  end

  defp value_width(%Signal{width: w}), do: w
  defp value_width(%Const{width: w}),  do: w
  defp value_width(_),                 do: nil

  # Minimum number of bits needed to hold a non-negative integer literal.
  # bits_needed(0)=1, bits_needed(0x30)=6, bits_needed(255)=8.
  def bits_needed(v) when is_integer(v) and v > 0, do: floor(:math.log2(v)) + 1
  def bits_needed(_), do: 1

  def infer_signedness(%Signal{signed: s}, _), do: s
  def infer_signedness(_, %Signal{signed: s}), do: s
  def infer_signedness(%Const{signed: s}, _), do: s
  def infer_signedness(_, %Const{signed: s}), do: s
  def infer_signedness(_, _), do: :unsigned

  # Match constant widths to signals in binary operations.
  #
  # A literal is widened to fit BOTH the signal's width AND the bits its own
  # value requires — it is never shrunk below what it needs to represent itself.
  # Old behaviour forced the const to exactly the signal width, so `0x30`
  # (needs 6 bits) paired with a 2-bit signal became a 2-bit const (value 0),
  # silently corrupting `0x30 + state`. Widening to max(signal, value) keeps the
  # literal intact; the result width (infer_width) then follows the wider side.
  def match_const_widths(%Const{value: v} = c, %Signal{} = s) do
    w = max(s.width, const_min_width(v))
    {%Const{c | width: w, signed: s.signed}, s}
  end
  def match_const_widths(%Signal{} = s, %Const{value: v} = c) do
    w = max(s.width, const_min_width(v))
    {s, %Const{c | width: w, signed: s.signed}}
  end
  def match_const_widths(%Const{} = a, %Const{} = b) do
    width = max(a.width, b.width)
    {%Const{a | width: width}, %Const{b | width: width}}
  end
  def match_const_widths(a, b), do: {a, b}

  # A literal's width is the max of its declared width and the bits its value
  # needs — :z and non-integers keep width 1.
  defp const_min_width(v) when is_integer(v), do: bits_needed(v)
  defp const_min_width(_), do: 1

  # Match a value's width to output signal (for assignments)
  def match_value_to_output(%Const{} = c, %Signal{} = sig) do
    %Const{c | width: sig.width, signed: sig.signed}
  end
  def match_value_to_output(value, _sig), do: value
end
