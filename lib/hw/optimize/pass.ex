defmodule Hw.Optimize.Pass do
  @moduledoc """
  Behaviour for IR optimization passes, plus the shared dataflow-graph core.

  An optimization pass is the write-enabled sibling of an analysis rule
  (`Hw.Analysis.Rule`): it walks the same fanin/fanout graph, but instead of
  *reporting* on the IR it *rewrites* it. Every pass is a pure
  `%Design{} -> %Design{}` function.

  ## Defining a pass

      defmodule Hw.Optimize.Passes.MyPass do
        @behaviour Hw.Optimize.Pass

        @impl true
        def name, do: :my_pass

        @impl true
        def run(%Design{} = design, _opts) do
          # ... transform ...
          design
        end
      end

  `run/2` returns just the `%Design{}`; the pass manager
  (`Hw.Optimize`) computes the `{ops_before, ops_after, signals_removed}`
  metrics by diffing the design before and after. A pass never has to
  bookkeep its own metrics.

  ## The dataflow graph (shared with the analysis rules)

  `Hw.IR.Design` is a flat `signals: [Signal]` + `ops: [op]` list where every
  op names its `output` signal. That makes the design a dataflow graph keyed by
  signal name for free:

    * `def_of/1`  — signal_name -> the single op that drives it
    * `uses_of/1` — signal_name -> the ops that read it

  Both are built by scanning each op's operand fields. The exhaustive
  field inventory lives in `operand_values/1` and `output_names/1` — the
  single source of truth for "what does this op read / drive". Any op type
  added to the IR must be taught to those two functions or the graph (and
  therefore every pass) will silently miss it.
  """

  alias Hw.IR.Design
  alias Hw.IR.Types.{Signal, Const}

  alias Hw.IR.Ops.{
    Add, Sub, Mul, Neg, Div, Mod, Abs, Min, Max, MulRound, Clog2,
    BitAnd, BitOr, BitNot, BitXor, Shl, Shr, Shra,
    ReduceAnd, ReduceOr, ReduceXor, Popcount,
    SignExtend, ZeroExtend, ReverseBits,
    Eq, Neq, Lt, Gt, Lte, Gte,
    Slice, Concat, Replicate, Cast,
    Mem, MemRead, MemWrite,
    Reg, Mux, Assign,
    Blackbox, Tristate,
    ComplexMul, ComplexAdd, ComplexSub, ComplexMagSq, ComplexConj
  }

  @callback name() :: atom()
  @callback run(Design.t(), keyword()) :: Design.t()

  # ---------------------------------------------------------------------------
  # Operand / output extraction — the single source of truth
  # ---------------------------------------------------------------------------

  @doc """
  Return the list of operand *values* an op reads.

  A value is whatever `Hw.Emit.Verilog.Ops.Value.emit_value/1` accepts:
  a `%Signal{}` reference, a `%Const{}`, a `%ParamRef{}`, or a bare atom.
  Clock references, memory-name atoms, and literal params (widths, counts,
  slice indices, cast kinds) are *not* operand values and are excluded.

  This is exhaustive over every op struct in `Hw.IR.Ops`.
  """
  # -- Binary combinational ops: read a, b --
  def operand_values(%Add{a: a, b: b}),  do: [a, b]
  def operand_values(%Sub{a: a, b: b}),  do: [a, b]
  def operand_values(%Mul{a: a, b: b}),  do: [a, b]
  def operand_values(%Div{a: a, b: b}),  do: [a, b]
  def operand_values(%Mod{a: a, b: b}),  do: [a, b]
  def operand_values(%Min{a: a, b: b}),  do: [a, b]
  def operand_values(%Max{a: a, b: b}),  do: [a, b]
  def operand_values(%MulRound{a: a, b: b}), do: [a, b]
  def operand_values(%BitAnd{a: a, b: b}), do: [a, b]
  def operand_values(%BitOr{a: a, b: b}),  do: [a, b]
  def operand_values(%BitXor{a: a, b: b}), do: [a, b]
  def operand_values(%Shl{a: a, b: b}),  do: [a, b]
  def operand_values(%Shr{a: a, b: b}),  do: [a, b]
  def operand_values(%Shra{a: a, b: b}), do: [a, b]
  def operand_values(%Eq{a: a, b: b}),   do: [a, b]
  def operand_values(%Neq{a: a, b: b}),  do: [a, b]
  def operand_values(%Lt{a: a, b: b}),   do: [a, b]
  def operand_values(%Gt{a: a, b: b}),   do: [a, b]
  def operand_values(%Lte{a: a, b: b}),  do: [a, b]
  def operand_values(%Gte{a: a, b: b}),  do: [a, b]

  # -- Unary combinational ops: read input --
  def operand_values(%Neg{input: i}),        do: [i]
  def operand_values(%Abs{input: i}),        do: [i]
  def operand_values(%Clog2{input: i}),      do: [i]
  def operand_values(%BitNot{input: i}),     do: [i]
  def operand_values(%ReduceAnd{input: i}),  do: [i]
  def operand_values(%ReduceOr{input: i}),   do: [i]
  def operand_values(%ReduceXor{input: i}),  do: [i]
  def operand_values(%Popcount{input: i}),   do: [i]
  def operand_values(%SignExtend{input: i}), do: [i]
  def operand_values(%ZeroExtend{input: i}), do: [i]
  def operand_values(%ReverseBits{input: i}),do: [i]
  def operand_values(%Replicate{input: i}),  do: [i]
  def operand_values(%Cast{input: i}),       do: [i]
  def operand_values(%Assign{input: i}),     do: [i]

  # -- Slice: input, plus hi/lo which may be %Const{} (a value) or a bare int --
  def operand_values(%Slice{input: i, hi: hi, lo: lo}) do
    [i | Enum.filter([hi, lo], &value?/1)]
  end

  # -- Concat: a list of values, MSB-first --
  def operand_values(%Concat{inputs: inputs}), do: inputs

  # -- Mux: every case cond and val, plus default, plus the casez selector
  #    (present only on case-derived muxes; read by casez emission) --
  def operand_values(%Mux{cases: cases, default: default, selector: sel}) do
    base = Enum.flat_map(cases, fn {cond, val} -> [cond, val] end) ++ [default]
    if sel, do: [sel | base], else: base
  end

  # -- Complex ops: read the re/im operands --
  def operand_values(%ComplexMul{a_re: ar, a_im: ai, b_re: br, b_im: bi}), do: [ar, ai, br, bi]
  def operand_values(%ComplexAdd{a_re: ar, a_im: ai, b_re: br, b_im: bi}), do: [ar, ai, br, bi]
  def operand_values(%ComplexSub{a_re: ar, a_im: ai, b_re: br, b_im: bi}), do: [ar, ai, br, bi]
  def operand_values(%ComplexMagSq{a_re: ar, a_im: ai}), do: [ar, ai]
  def operand_values(%ComplexConj{a_re: ar, a_im: ai}), do: [ar, ai]

  # -- Sequential / stateful ops --
  # Reg reads: input (D), enable, reset_value. clock/async_reset are NOT data.
  def operand_values(%Reg{input: i, enable: en, reset_value: rv}) do
    Enum.filter([i, en, rv], &value?/1)
  end

  # MemRead reads its address (memory name + clock are not data values).
  def operand_values(%MemRead{addr: addr}), do: [addr]

  # MemWrite reads addr, data, enable (memory name + clock are not data values).
  def operand_values(%MemWrite{addr: addr, data: data, enable: en}), do: [addr, data, en]

  # Mem declaration reads nothing.
  def operand_values(%Mem{}), do: []

  # Blackbox reads each connected port value.
  def operand_values(%Blackbox{ports: ports}) do
    Enum.map(ports, fn {_port, conn} -> conn end)
  end

  # Tristate reads output_value, output_enable, input_value.
  # (io is the driven pad, i.e. an output side — see output_names/1.)
  def operand_values(%Tristate{output_value: ov, output_enable: oe, input_value: iv}) do
    Enum.filter([ov, oe, iv], &value?/1)
  end

  @doc """
  Return the list of signal *names* an op drives.

  Most ops drive exactly one (`op.output.name`). Complex ops drive two.
  Declarations / stateless side-effect ops (`Mem`, `MemWrite`, `Blackbox`)
  drive none through a `Signal` output. `Tristate` drives its `input_value`
  wire (the read-back of the pad).
  """
  def output_names(%{output: %Signal{name: name}}), do: [name]

  def output_names(%ComplexMul{output_re: re, output_im: im}), do: [re.name, im.name]
  def output_names(%ComplexAdd{output_re: re, output_im: im}), do: [re.name, im.name]
  def output_names(%ComplexSub{output_re: re, output_im: im}), do: [re.name, im.name]
  # ComplexMagSq has a single `output` field, covered by the generic clause above.
  def output_names(%ComplexConj{output_re: re, output_im: im}), do: [re.name, im.name]

  # Tristate drives the input_value read-back wire (io is a bidirectional pad,
  # typically a top-level inout port, so it is observable and not a plain net).
  def output_names(%Tristate{input_value: %Signal{name: n}}), do: [n]
  def output_names(%Tristate{}), do: []

  # No Signal-typed output.
  def output_names(%Mem{}), do: []
  def output_names(%MemWrite{}), do: []
  def output_names(%Blackbox{}), do: []
  def output_names(_), do: []

  @doc "True if `v` is an operand value (references a signal by name)."
  def value?(%Signal{}), do: true
  def value?(_), do: false

  @doc """
  Extract the referenced signal name from an operand value, or `nil` if the
  value is not a signal reference (a `%Const{}`, `%ParamRef{}`, bare int, etc.).
  """
  def ref_name(%Signal{name: name}), do: name
  def ref_name(_), do: nil

  @doc """
  Return the set of signal names referenced OUTSIDE the op operand graph, which
  a pass must therefore never eliminate or rename.

  The Verilog backend emits some signals by NAME through convention rather than
  through an op's operand field, so `uses_of/1` shows them with no users even
  though removing them breaks the design:

    * Clock names go into `always @(posedge clk)` sensitivity lists.
    * Each clock's `reset_signal` (default `:rst`) is emitted literally into
      `if (rst) ...` reset blocks (see
      `Hw.Emit.Verilog.Sequential.emit_clock_block/3`).
    * Any `Reg.async_reset` name goes into the sensitivity list and reset test.
  """
  @spec pinned_names(Design.t()) :: MapSet.t(atom())
  def pinned_names(%Design{clocks: clocks, ops: ops}) do
    clock_names = Enum.map(clocks, & &1.name)

    reset_signals =
      clocks
      |> Enum.map(&Map.get(&1, :reset_signal))
      |> Enum.reject(&is_nil/1)

    async_resets =
      Enum.flat_map(ops, fn
        %Reg{async_reset: ar} when not is_nil(ar) -> [ar]
        _ -> []
      end)

    # `:rst` is the hard-coded fallback reset name in the sequential emitter.
    MapSet.new([:rst | clock_names ++ reset_signals ++ async_resets])
  end

  # ---------------------------------------------------------------------------
  # Graph builders
  # ---------------------------------------------------------------------------

  @doc """
  Build `signal_name => driving op` for every op that drives a signal.

  The single-driver invariant is enforced by validation, so each name maps to
  exactly one op. An op with multiple outputs (Complex*) appears under each of
  its output names.
  """
  @spec def_of(Design.t()) :: %{atom() => struct()}
  def def_of(%Design{ops: ops}) do
    Enum.reduce(ops, %{}, fn op, acc ->
      Enum.reduce(output_names(op), acc, fn name, a -> Map.put(a, name, op) end)
    end)
  end

  @doc """
  Build `signal_name => [ops that read it]`.

  Only signal references count as uses; constants and params do not create
  fanout edges. Reading order within the list is unspecified.
  """
  @spec uses_of(Design.t()) :: %{atom() => [struct()]}
  def uses_of(%Design{ops: ops}) do
    Enum.reduce(ops, %{}, fn op, acc ->
      op
      |> operand_values()
      |> Enum.map(&ref_name/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reduce(acc, fn name, a ->
        Map.update(a, name, [op], fn ops -> [op | ops] end)
      end)
    end)
  end

  @doc """
  Rewrite every reference to signal name `from` into a reference to signal
  `to_signal` (a `%Signal{}`), across all operand fields of every op in the
  design. Output fields are left untouched.

  This is the core rewrite primitive used by CSE and DCE: after choosing a
  surviving signal, redirect all fanout of the dead signal onto it.
  """
  @spec rewrite_uses(Design.t(), atom(), Signal.t()) :: Design.t()
  def rewrite_uses(%Design{ops: ops} = design, from, %Signal{} = to_signal)
      when is_atom(from) do
    remap = fn v -> remap_value(v, from, to_signal) end
    %{design | ops: Enum.map(ops, &rewrite_op_operands(&1, remap))}
  end

  @doc """
  Like `rewrite_uses/3` but remaps against a whole substitution map
  `%{signal_name => survivor %Signal{}}` in a SINGLE walk over each op.

  Used by CSE's final rewrite so the cost is O(ops) rather than
  O(ops * substitutions).
  """
  @spec rewrite_uses_map(Design.t(), %{atom() => Signal.t()}) :: Design.t()
  def rewrite_uses_map(%Design{ops: ops} = design, subst) when is_map(subst) do
    remap = fn
      %Signal{name: name} = sig -> Map.get(subst, name, sig)
      other -> other
    end

    %{design | ops: Enum.map(ops, &rewrite_op_operands(&1, remap))}
  end

  # Rewrite operand fields of a single op via the `remap` function (value ->
  # value). We match the exact operand-bearing fields per op struct (mirroring
  # operand_values/1). Output fields are never rewritten.
  defp rewrite_op_operands(op, remap) do
    case op do
      # Binary ops
      %{__struct__: s, a: _, b: _} = o
      when s in [Add, Sub, Mul, Div, Mod, Min, Max, MulRound,
                 BitAnd, BitOr, BitXor, Shl, Shr, Shra,
                 Eq, Neq, Lt, Gt, Lte, Gte] ->
        %{o | a: remap.(o.a), b: remap.(o.b)}

      # Unary "input" ops
      %{__struct__: s, input: _} = o
      when s in [Neg, Abs, Clog2, BitNot, ReduceAnd, ReduceOr, ReduceXor,
                 Popcount, SignExtend, ZeroExtend, ReverseBits, Replicate,
                 Cast, Assign] ->
        %{o | input: remap.(o.input)}

      %Slice{} = o ->
        %{o | input: remap.(o.input), hi: remap.(o.hi), lo: remap.(o.lo)}

      %Concat{inputs: inputs} = o ->
        %{o | inputs: Enum.map(inputs, remap)}

      %Mux{cases: cases, default: default} = o ->
        %{o |
          cases: Enum.map(cases, fn {c, v} -> {remap.(c), remap.(v)} end),
          default: remap.(default),
          selector: remap.(o.selector)}

      %ComplexMul{} = o ->
        %{o | a_re: remap.(o.a_re), a_im: remap.(o.a_im), b_re: remap.(o.b_re), b_im: remap.(o.b_im)}
      %ComplexAdd{} = o ->
        %{o | a_re: remap.(o.a_re), a_im: remap.(o.a_im), b_re: remap.(o.b_re), b_im: remap.(o.b_im)}
      %ComplexSub{} = o ->
        %{o | a_re: remap.(o.a_re), a_im: remap.(o.a_im), b_re: remap.(o.b_re), b_im: remap.(o.b_im)}
      %ComplexMagSq{} = o ->
        %{o | a_re: remap.(o.a_re), a_im: remap.(o.a_im)}
      %ComplexConj{} = o ->
        %{o | a_re: remap.(o.a_re), a_im: remap.(o.a_im)}

      %Reg{} = o ->
        %{o | input: remap.(o.input), enable: remap.(o.enable), reset_value: remap.(o.reset_value)}

      %MemRead{} = o ->
        %{o | addr: remap.(o.addr)}

      %MemWrite{} = o ->
        %{o | addr: remap.(o.addr), data: remap.(o.data), enable: remap.(o.enable)}

      %Blackbox{ports: ports} = o ->
        %{o | ports: Enum.map(ports, fn {p, conn} -> {p, remap.(conn)} end)}

      %Tristate{} = o ->
        %{o | output_value: remap.(o.output_value),
              output_enable: remap.(o.output_enable),
              input_value: remap.(o.input_value)}

      # Mem declaration and anything without operands: unchanged.
      other ->
        other
    end
  end

  # Replace a %Signal{} named `from` with `to`; leave everything else as-is.
  defp remap_value(%Signal{name: from}, from, to), do: to
  defp remap_value(other, _from, _to), do: other

  @doc false
  # Convenience used by passes to test purity for dedup eligibility.
  def const?(%Const{}), do: true
  def const?(_), do: false
end
