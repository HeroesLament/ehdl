defmodule OptimizeCSETest do
  @moduledoc """
  Unit tests for the Pass 1 IR optimizer: the shared graph builder
  (`Hw.Optimize.Pass`) and the `CSE` pass. These build IR directly (no DSL, no
  sim) so behaviour is asserted deterministically on hand-constructed designs.
  """

  use ExUnit.Case, async: true

  alias Hw.IR.Design
  alias Hw.IR.Types.{Signal, Const}
  alias Hw.IR.Ops.{BitAnd, BitXor, Reg, Slice, Concat, Assign, Sub}
  alias Hw.Optimize
  alias Hw.Optimize.Pass

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp sig(name, width \\ 8, dir \\ :internal),
    do: %Signal{name: name, width: width, signed: :unsigned, direction: dir}

  defp c(v, w \\ 8), do: %Const{value: v, width: w, signed: :unsigned}

  defp design(signals, ops) do
    %Design{name: :test, signals: signals, ops: ops, clocks: [], params: [], localparams: []}
  end

  defp cse(design), do: Optimize.run(design, optimize: true, only: [:cse])

  defp op_outputs(design) do
    design.ops
    |> Enum.flat_map(&Pass.output_names/1)
    |> Enum.sort()
  end

  # ─── graph builder ─────────────────────────────────────────────────────────

  describe "Pass.def_of / uses_of / operand_values" do
    test "def_of maps each output name to its driving op" do
      a = sig(:a)
      b = sig(:b)
      x = sig(:x, 8, :input)
      op = %BitAnd{output: a, a: x, b: b}
      d = design([a, b, x], [op])

      assert Pass.def_of(d) == %{a: op}
    end

    test "uses_of records fanout by signal name, constants excluded" do
      x = sig(:x, 8, :input)
      out = sig(:out, 8, :output)
      op = %BitAnd{output: out, a: x, b: c(255)}
      d = design([x, out], [op])

      uses = Pass.uses_of(d)
      assert uses[:x] == [op]
      refute Map.has_key?(uses, :out)
    end

    test "operand_values scans Mux cases + default and Reg data/enable/reset" do
      s1 = sig(:s1, 1)
      v1 = sig(:v1)
      dflt = sig(:dflt)
      mux = %Hw.IR.Ops.Mux{output: sig(:m), cases: [{s1, v1}], default: dflt}
      assert Pass.operand_values(mux) == [s1, v1, dflt]

      clk = %Hw.IR.Types.Clock{name: :clk, edge: :posedge}
      reg = %Reg{output: sig(:q), input: sig(:d), clock: clk, enable: sig(:en), reset_value: c(0)}
      names = reg |> Pass.operand_values() |> Enum.map(&Pass.ref_name/1)
      assert :d in names
      assert :en in names
      refute :clk in names
    end
  end

  # ─── CSE: basic dedup ──────────────────────────────────────────────────────

  describe "CSE dedup of identical pure ops" do
    test "two identical BitAnd cones collapse to one; uses rewired" do
      x = sig(:x, 8, :input)
      y = sig(:y, 8, :input)
      t1 = sig(:t1)
      t2 = sig(:t2)
      out = sig(:out, 8, :output)

      ops = [
        %BitAnd{output: t1, a: x, b: y},
        %BitAnd{output: t2, a: x, b: y},
        %Sub{output: out, a: t1, b: t2}
      ]

      d = cse(design([x, y, t1, t2, out], ops))

      outs = op_outputs(d)
      assert :out in outs
      assert length(Enum.filter(outs, &(&1 in [:t1, :t2]))) == 1

      sub = Enum.find(d.ops, &match?(%Sub{}, &1))
      assert Pass.ref_name(sub.a) == Pass.ref_name(sub.b)
    end

    test "commutative ops dedup regardless of operand order" do
      x = sig(:x, 8, :input)
      y = sig(:y, 8, :input)
      t1 = sig(:t1)
      t2 = sig(:t2)
      out = sig(:out, 8, :output)

      ops = [
        %BitXor{output: t1, a: x, b: y},
        %BitXor{output: t2, a: y, b: x},
        %Sub{output: out, a: t1, b: t2}
      ]

      d = cse(design([x, y, t1, t2, out], ops))
      assert Enum.count(d.ops, &match?(%BitXor{}, &1)) == 1
    end

    test "non-commutative ops do NOT dedup when operands are swapped" do
      x = sig(:x, 8, :input)
      y = sig(:y, 8, :input)
      t1 = sig(:t1)
      t2 = sig(:t2)
      out = sig(:out, 8, :output)

      ops = [
        %Sub{output: t1, a: x, b: y},
        %Sub{output: t2, a: y, b: x},
        %Hw.IR.Ops.Add{output: out, a: t1, b: t2}
      ]

      d = cse(design([x, y, t1, t2, out], ops))
      assert Enum.count(d.ops, &match?(%Sub{}, &1)) == 2
    end
  end

  # ─── CSE: safety guarantees ─────────────────────────────────────────────────

  describe "CSE safety" do
    test "never dedups Reg ops even with identical inputs" do
      x = sig(:x, 8, :input)
      clk = %Hw.IR.Types.Clock{name: :clk, edge: :posedge}
      q1 = sig(:q1)
      q2 = sig(:q2)
      out = sig(:out, 8, :output)

      ops = [
        %Reg{output: q1, input: x, clock: clk},
        %Reg{output: q2, input: x, clock: clk},
        %Hw.IR.Ops.Add{output: out, a: q1, b: q2}
      ]

      d = cse(design([x, q1, q2, out], ops))
      assert Enum.count(d.ops, &match?(%Reg{}, &1)) == 2
    end

    test "never eliminates an op that drives an output port" do
      x = sig(:x, 8, :input)
      y = sig(:y, 8, :input)
      o1 = sig(:o1, 8, :output)
      o2 = sig(:o2, 8, :output)

      ops = [
        %BitAnd{output: o1, a: x, b: y},
        %BitAnd{output: o2, a: x, b: y}
      ]

      d = cse(design([x, y, o1, o2], ops))
      assert Enum.sort(op_outputs(d)) == [:o1, :o2]
    end
  end

  # ─── CSE: normalization / alias collapse ────────────────────────────────────

  describe "CSE alias collapse" do
    test "identity full-width slice collapses to its source" do
      x = sig(:x, 8, :input)
      t = sig(:t, 8)
      out = sig(:out, 8, :output)

      ops = [
        %Slice{output: t, input: x, hi: 7, lo: 0},
        %Assign{output: out, input: t}
      ]

      d = cse(design([x, t, out], ops))
      refute Enum.any?(d.ops, &match?(%Slice{}, &1))
      assign = Enum.find(d.ops, &match?(%Assign{}, &1))
      assert Pass.ref_name(assign.input) == :x
    end

    test "partial slice is NOT treated as an alias" do
      x = sig(:x, 8, :input)
      t = sig(:t, 4)
      out = sig(:out, 4, :output)

      ops = [
        %Slice{output: t, input: x, hi: 3, lo: 0},
        %Assign{output: out, input: t}
      ]

      d = cse(design([x, t, out], ops))
      assert Enum.any?(d.ops, &match?(%Slice{}, &1))
    end

    test "single-element concat collapses to its element" do
      x = sig(:x, 8, :input)
      t = sig(:t, 8)
      out = sig(:out, 8, :output)

      ops = [
        %Concat{output: t, inputs: [x]},
        %Assign{output: out, input: t}
      ]

      d = cse(design([x, t, out], ops))
      refute Enum.any?(d.ops, &match?(%Concat{}, &1))
      assign = Enum.find(d.ops, &match?(%Assign{}, &1))
      assert Pass.ref_name(assign.input) == :x
    end
  end

  # ─── CSE: pinned (out-of-band) signals ──────────────────────────────────────

  describe "CSE never eliminates signals referenced outside the op graph" do
    # The sequential emitter references clock and reset signals BY NAME (into
    # `always @(posedge clk)` and `if (rst)` blocks), not through op operands.
    # CSE's dataflow graph can't see those uses, so it must treat them as pinned
    # or it silently deletes the reset and the whole design collapses on silicon.
    test "a reset signal duplicated by an Assign is NOT merged away" do
      clk = %Hw.IR.Types.Clock{name: :clk, edge: :posedge, reset_signal: :rst}
      src = sig(:_rst_src, 1, :input)
      rst = sig(:rst, 1)
      other = sig(:other_copy, 1)
      q = sig(:q, 8)
      d = sig(:d, 8, :input)

      # rst and other_copy both = _rst_src → same CSE key. rst must survive
      # because the reg block references it by name.
      ops = [
        %Assign{output: rst, input: src},
        %Assign{output: other, input: src},
        %Reg{output: q, input: d, clock: clk, reset_value: c(0)}
      ]

      design = %Design{
        name: :t, clocks: [clk], params: [], localparams: [],
        signals: [src, rst, other, q, d],
        ops: ops
      }

      out = Optimize.run(design, optimize: true, only: [:cse])
      driven = out.ops |> Enum.flat_map(&Pass.output_names/1) |> MapSet.new()
      assert MapSet.member?(driven, :rst), "reset signal :rst was eliminated by CSE"
    end

    test "pinned_names includes clocks, reset signals, and :rst fallback" do
      clk = %Hw.IR.Types.Clock{name: :clk_48, edge: :posedge, reset_signal: :sys_rst}
      design = %Design{
        name: :t, clocks: [clk], params: [], localparams: [], signals: [], ops: []
      }

      pinned = Pass.pinned_names(design)
      assert MapSet.member?(pinned, :clk_48)
      assert MapSet.member?(pinned, :sys_rst)
      assert MapSet.member?(pinned, :rst)
    end
  end

  # ─── inertness ──────────────────────────────────────────────────────────────

  describe "optimizer wiring" do
    test "run/2 is a no-op without opts[:optimize]" do
      x = sig(:x, 8, :input)
      t1 = sig(:t1)
      t2 = sig(:t2)
      out = sig(:out, 8, :output)

      ops = [
        %BitAnd{output: t1, a: x, b: x},
        %BitAnd{output: t2, a: x, b: x},
        %Sub{output: out, a: t1, b: t2}
      ]

      d = design([x, t1, t2, out], ops)
      assert Optimize.run(d, []) == d
      assert Optimize.run(d, only: [:cse]) == d
    end

    test "chained equal cones fully collapse via substitution" do
      x = sig(:x, 8, :input)
      a1 = sig(:a1)
      a2 = sig(:a2)
      b1 = sig(:b1)
      b2 = sig(:b2)
      out = sig(:out, 8, :output)

      ops = [
        %BitXor{output: a1, a: x, b: x},
        %BitXor{output: a2, a: x, b: x},
        %BitAnd{output: b1, a: a1, b: x},
        %BitAnd{output: b2, a: a2, b: x},
        %Sub{output: out, a: b1, b: b2}
      ]

      d = cse(design([x, a1, a2, b1, b2, out], ops))
      assert Enum.count(d.ops, &match?(%BitXor{}, &1)) == 1
      assert Enum.count(d.ops, &match?(%BitAnd{}, &1)) == 1
    end
  end
end
