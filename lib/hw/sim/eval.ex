defmodule Hw.Sim.Eval do
  @moduledoc """
  Pure integer evaluator for EHDL IR ops.

  All signals are represented as non-negative integers masked to their
  declared width. Elixir's arbitrary-precision integers mean we never
  overflow — we just mask on write.

  The evaluator takes an op and the current signal state map, and returns
  the new value for the op's output signal. It does NOT update state —
  that's the caller's responsibility.

  Regs are NOT evaluated here — they are latched by the clock process.
  During comb evaluation, a Reg's output is just read from the state map
  (its current latched value).
  """

  import Bitwise

  alias Hw.IR.Ops.{Assign, Add, Sub, Mul, Div, Neg, Mod, Abs, Min, Max, Clog2,
                   Mux, Eq, Neq, Lt, Gt, Lte, Gte, BitAnd, BitOr, BitXor,
                   BitNot, Shl, Shr, Shra, ReduceAnd, ReduceOr, ReduceXor,
                   Replicate, Cast, Slice, Concat, Reg, Blackbox, Tristate, MemRead,
                   ZeroExtend, SignExtend, ReverseBits, Popcount, MulRound}
  alias Hw.IR.Types.{Signal, Const}

  @doc """
  Evaluate a single comb op against the current signal state.
  Returns `{output_signal_name, new_value}` or a list of them for
  multi-output ops (Blackbox, Tristate).

  Regs return their current value unchanged — callers should not pass
  Reg ops to this function during comb evaluation.
  """
  def eval(op, state, widths, memories \\ %{})

  def eval(%Assign{output: out, input: input}, state, widths, _mems) do
    val = read(input, state)
    [{out.name, mask(val, width(out, widths))}]
  end

  def eval(%Add{output: out, a: a, b: b}, state, widths, _mems) do
    val = read(a, state) + read(b, state)
    [{out.name, mask(val, width(out, widths))}]
  end

  def eval(%Sub{output: out, a: a, b: b}, state, widths, _mems) do
    # Subtraction wraps at width (two's complement truncation)
    val = read(a, state) - read(b, state)
    [{out.name, mask(val, width(out, widths))}]
  end

  def eval(%Mul{output: out, a: a, b: b}, state, widths, _mems) do
    val = read(a, state) * read(b, state)
    [{out.name, mask(val, width(out, widths))}]
  end

  def eval(%Div{output: out, a: a, b: b}, state, widths, _mems) do
    divisor = read(b, state)
    val = if divisor == 0, do: 0, else: div(read(a, state), divisor)
    [{out.name, mask(val, width(out, widths))}]
  end

  def eval(%Eq{output: out, a: a, b: b}, state, _widths, _mems) do
    val = if read(a, state) == read(b, state), do: 1, else: 0
    [{out.name, val}]
  end

  def eval(%Lt{output: out, a: a, b: b}, state, _widths, _mems) do
    val = if read(a, state) < read(b, state), do: 1, else: 0
    [{out.name, val}]
  end

  def eval(%Gt{output: out, a: a, b: b}, state, _widths, _mems) do
    val = if read(a, state) > read(b, state), do: 1, else: 0
    [{out.name, val}]
  end

  def eval(%BitAnd{output: out, a: a, b: b}, state, widths, _mems) do
    val = band(read(a, state), read(b, state))
    [{out.name, mask(val, width(out, widths))}]
  end

  def eval(%BitOr{output: out, a: a, b: b}, state, widths, _mems) do
    val = bor(read(a, state), read(b, state))
    [{out.name, mask(val, width(out, widths))}]
  end

  def eval(%BitXor{output: out, a: a, b: b}, state, widths, _mems) do
    val = bxor(read(a, state), read(b, state))
    [{out.name, mask(val, width(out, widths))}]
  end

  def eval(%BitNot{output: out, input: input}, state, widths, _mems) do
    w = width(out, widths)
    # Bitwise NOT masked to width — equivalent to XOR with all-ones mask
    val = bxor(read(input, state), mask(-1, w))
    [{out.name, mask(val, w)}]
  end

  def eval(%Slice{output: out, input: input, hi: hi, lo: lo}, state, _widths, _mems) do
    hi_val = const_val(hi)
    lo_val = const_val(lo)
    w = hi_val - lo_val + 1
    val = read(input, state) >>> lo_val
    [{out.name, mask(val, w)}]
  end

  def eval(%Concat{output: out, inputs: inputs}, state, widths, _mems) do
    # IR stores inputs MSB-first. Iterate in reverse so the last input
    # (LSB) accumulates at shift=0, working upward toward MSB.
    {val, _shift} = Enum.reduce(Enum.reverse(inputs), {0, 0}, fn input, {acc, shift} ->
      w = input_width(input, widths)
      {acc ||| (read(input, state) <<< shift), shift + w}
    end)
    [{out.name, mask(val, width(out, widths))}]
  end

  def eval(%Mux{output: out, cases: cases, default: default}, state, widths, _mems) do
    val = Enum.find_value(cases, fn {cond, result} ->
      if read(cond, state) != 0, do: read(result, state)
    end) || read(default, state)
    [{out.name, mask(val, width(out, widths))}]
  end

  def eval(%MemRead{output: out, memory: mem_name, addr: addr}, state, widths, memories) do
    mem = Map.fetch!(memories, mem_name)
    idx = read(addr, state)
    val = Enum.at(mem, idx, 0)
    [{out.name, mask(val, width(out, widths))}]
  end

  # Blackbox — model as transparent pass-through of zero for unknown outputs.
  # PLL and DCCA outputs (clocks) are injected by the clock process directly,
  # so we just emit zeros here as a safe default. In practice the clock signals
  # get overridden before any logic reads them.
  def eval(%Blackbox{ports: ports}, _state, _widths, _mems) do
    ports
    |> Enum.filter(fn {_, v} -> match?(%Signal{}, v) end)
    |> Enum.map(fn {_, %Signal{name: name}} -> {name, 0} end)
  end

  # Tristate — during simulation we model the bidirectional pin as:
  # - If output_enable is high: drive output_value onto the bus
  # - The input_value reflects what's on the bus (driven externally by testbench)
  # We only set the output here; input_value is written by the testbench.
  def eval(%Tristate{output_value: ov, output_enable: oe, input_value: iv}, state, _widths, _mems) do
    enabled = read(oe, state) != 0
    driven  = if enabled, do: read(ov, state), else: 0
    # input_value is not driven by this op — testbench owns it
    # We still return it unchanged so state stays consistent
    current_in = Map.get(state, iv.name, 0)
    [{iv.name, current_in}, {ov.name, driven}]
  end

  # Reg — during comb evaluation, just return current value (no change).
  # Latching is handled by the clock process.
  # --- Comparison ---

  def eval(%Neq{output: out, a: a, b: b}, state, _widths, _mems) do
    [{out.name, if(read(a, state) != read(b, state), do: 1, else: 0)}]
  end

  def eval(%Lte{output: out, a: a, b: b}, state, _widths, _mems) do
    [{out.name, if(read(a, state) <= read(b, state), do: 1, else: 0)}]
  end

  def eval(%Gte{output: out, a: a, b: b}, state, _widths, _mems) do
    [{out.name, if(read(a, state) >= read(b, state), do: 1, else: 0)}]
  end

  # --- Arithmetic ---

  def eval(%Neg{output: out, input: input}, state, widths, _mems) do
    w = width(out, widths)
    [{out.name, mask(-read(input, state), w)}]
  end

  def eval(%Mod{output: out, a: a, b: b}, state, widths, _mems) do
    w = width(out, widths)
    [{out.name, mask(rem(read(a, state), read(b, state)), w)}]
  end

  def eval(%Abs{output: out, input: input}, state, widths, _mems) do
    w = width(out, widths)
    [{out.name, mask(abs(read(input, state)), w)}]
  end

  def eval(%Min{output: out, a: a, b: b}, state, widths, _mems) do
    w = width(out, widths)
    [{out.name, mask(min(read(a, state), read(b, state)), w)}]
  end

  def eval(%Max{output: out, a: a, b: b}, state, widths, _mems) do
    w = width(out, widths)
    [{out.name, mask(max(read(a, state), read(b, state)), w)}]
  end

  def eval(%Clog2{output: out, input: input}, state, widths, _mems) do
    w = width(out, widths)
    v = read(input, state)
    result = if v <= 1, do: 0, else: :math.log2(v) |> Float.ceil() |> trunc()
    [{out.name, mask(result, w)}]
  end

  # --- Bitwise shifts ---

  def eval(%Shl{output: out, a: a, b: b}, state, widths, _mems) do
    w = width(out, widths)
    [{out.name, mask(read(a, state) <<< read(b, state), w)}]
  end

  def eval(%Shr{output: out, a: a, b: b}, state, widths, _mems) do
    w = width(out, widths)
    [{out.name, mask(read(a, state) >>> read(b, state), w)}]
  end

  def eval(%Shra{output: out, a: a, b: b}, state, widths, _mems) do
    w = width(out, widths)
    v = read(a, state)
    shift = read(b, state)
    sign = v >>> (w - 1)
    result = if sign == 1 do
      fill = ((1 <<< shift) - 1) <<< (w - shift)
      (v >>> shift) ||| fill
    else
      v >>> shift
    end
    [{out.name, mask(result, w)}]
  end

  # --- Reductions ---

  def eval(%ReduceAnd{output: out, input: input}, state, widths, _mems) do
    input_w = Map.get(widths, input.name, 1)
    v = read(input, state)
    [{out.name, if(v == (1 <<< input_w) - 1, do: 1, else: 0)}]
  end

  def eval(%ReduceOr{output: out, input: input}, state, _widths, _mems) do
    [{out.name, if(read(input, state) != 0, do: 1, else: 0)}]
  end

  def eval(%ReduceXor{output: out, input: input}, state, _widths, _mems) do
    v = read(input, state)
    parity = v |> Integer.digits(2) |> Enum.sum() |> rem(2)
    [{out.name, parity}]
  end

  # --- Replicate ---

  def eval(%Replicate{output: out, input: input, count: count}, state, widths, _mems) do
    w = width(out, widths)
    v = read(input, state)
    n = read(count, state)
    bit_w = if n > 0, do: div(w, n), else: w
    result = Enum.reduce(0..(n - 1), 0, fn i, acc -> acc ||| (v <<< (i * bit_w)) end)
    [{out.name, mask(result, w)}]
  end

  # --- Cast (width/sign conversion) ---

  def eval(%Cast{output: out, input: input}, state, widths, _mems) do
    w = width(out, widths)
    [{out.name, mask(read(input, state), w)}]
  end

  # --- Registers ---

  def eval(%Reg{output: out}, state, widths, _mems) do
    val = Map.get(state, out.name, 0)
    [{out.name, mask(val, width(out, widths))}]
  end

  # Mem definition — no output, just initializes memory state
  def eval(%Hw.IR.Ops.Mem{}, _state, _widths, _mems), do: []

  # ---------------------------------------------------------------------------
  # Reg latching — called by clock process on clock edge
  # ---------------------------------------------------------------------------

  @doc """
  Compute the next value for a register given current state.
  Called during Phase 1 (evaluate) of the clock edge cycle.
  Returns `{reg_output_name, next_value}`.
  """
  def eval_reg_next(%Reg{output: out, input: input, enable: enable, reset_value: reset_val,
                          async_reset: async_reset}, state, widths) do
    w = width(out, widths)

    cond do
      # Async reset takes priority
      async_reset != nil and read(async_reset, state) != 0 ->
        {out.name, mask(reset_val || 0, w)}

      # Enable gating — if enable is present and low, hold current value
      enable != nil and read(enable, state) == 0 ->
        {out.name, Map.get(state, out.name, 0)}

      # Normal clock — capture input
      true ->
        {out.name, mask(read(input, state), w)}
    end
  end

  # ---------------------------------------------------------------------------
  # Width-changing and bit-counting ops
  #
  # These existed in Hw.Sim.Compiler but not here, so any design reaching the
  # interpreted path died with a FunctionClauseError rather than a useful
  # message — which is what broke the hello_board suite on the USB SIE's CRC
  # buffer. ReverseBits and Popcount are implemented properly here; the
  # compiler currently approximates them (pass-through and reduce_or), so the
  # two paths do NOT agree for those ops yet.
  # ---------------------------------------------------------------------------

  def eval(%ZeroExtend{output: out, input: input}, state, widths, _mems) do
    # Value is unchanged, only the declared width grows. Mask anyway so a
    # wider-than-declared input cannot leak high bits through.
    [{out.name, mask(read(input, state), width(out, widths))}]
  end

  def eval(%SignExtend{output: out, input: input}, state, widths, _mems) do
    in_w = width(input, widths)
    out_w = width(out, widths)
    val = mask(read(input, state), in_w)

    extended =
      if in_w > 0 and out_w > in_w and ((val >>> (in_w - 1)) &&& 1) == 1 do
        val ||| (((1 <<< (out_w - in_w)) - 1) <<< in_w)
      else
        val
      end

    [{out.name, mask(extended, out_w)}]
  end

  def eval(%ReverseBits{output: out, input: input}, state, widths, _mems) do
    in_w = width(input, widths)
    val = mask(read(input, state), in_w)

    reversed =
      Enum.reduce(0..(in_w - 1)//1, 0, fn i, acc ->
        acc ||| (((val >>> i) &&& 1) <<< (in_w - 1 - i))
      end)

    [{out.name, mask(reversed, width(out, widths))}]
  end

  def eval(%Popcount{output: out, input: input}, state, widths, _mems) do
    in_w = width(input, widths)
    val = mask(read(input, state), in_w)
    count = Enum.count(0..(in_w - 1)//1, &(((val >>> &1) &&& 1) == 1))
    [{out.name, mask(count, width(out, widths))}]
  end

  def eval(%MulRound{output: out, a: a, b: b, shift: shift}, state, widths, _mems) do
    s = if is_integer(shift), do: shift, else: read(shift, state)
    prod = read(a, state) * read(b, state)
    val = if s > 0, do: (prod + (1 <<< (s - 1))) >>> s, else: prod
    [{out.name, mask(val, width(out, widths))}]
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Unwrap a Const or pass through a raw integer
  defp const_val(%Const{value: v}), do: v
  defp const_val(v) when is_integer(v), do: v

  # Read a signal or constant from state
  defp read(%Signal{name: name}, state), do: Map.get(state, name, 0)
  defp read(%Const{value: v}, _state),   do: v
  defp read(nil, _state),                do: 0

  # Width of an output signal
  defp width(%Signal{width: w}, _widths), do: w
  defp width(%Const{width: w}, _widths),  do: w

  # Width of an input (for Concat)
  defp input_width(%Signal{width: w}, _widths), do: w
  defp input_width(%Const{width: w}, _widths),  do: w
  defp input_width(name, widths) when is_atom(name), do: Map.get(widths, name, 1)

  # Mask a value to n bits
  defp mask(val, width) when width >= 64, do: val &&& ((1 <<< width) - 1)
  defp mask(val, width), do: val &&& ((1 <<< width) - 1)
end
