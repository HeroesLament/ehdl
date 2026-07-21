defmodule Hw.Compile.Elaborate.Sequential do
  @moduledoc """
  Sequential logic elaboration: mux trees, reset extraction, memory writes.

  ## Binary pattern case (casez)

  When a `case` statement uses `<<>>` binary patterns (parsed by
  `Hw.DSL.Primitives.Parse` into `{:binary_pattern, segments, width}`
  clause patterns), this module emits Verilog `casez`-style logic by
  building a mask/value pair for each arm.

  For each pattern arm:
  - Literal segments contribute exact bits to the match value
  - Wildcard segments (`_::N`) contribute don't-care bits
  - Named capture segments contribute exact bits AND expose slice
    expressions that the body may reference

  The elaborated IR is identical to a regular case mux — we use
  `Ops.Mux` with equality conditions, but the equality is against a
  masked value. The Verilog emitter can optionally recognize the
  `casez_hint: true` flag on the Mux op and emit `casez` instead of
  a chain of ternaries (future optimization — for now correctness
  is guaranteed by the mask/value equality logic).
  """

  alias Hw.IR.Design
  alias Hw.IR.Types.{Signal, Const}
  alias Hw.IR.Ops
  alias Hw.Compile.Elaborate.Expr

  # --- Find All Assigned Signals ---

  @doc """
  Returns {signal_targets, mem_writes} from a list of statements.
  """
  def find_all_assigned(statements) when is_list(statements) do
    find_all_assigned(statements, {:const, 1})
  end

  def find_all_assigned(statements, enable_cond) when is_list(statements) do
    {signals, mems} = statements
    |> Enum.map(&find_assigned_in_statement(&1, enable_cond))
    |> Enum.reduce({[], []}, fn {s, m}, {acc_s, acc_m} ->
      {acc_s ++ s, acc_m ++ m}
    end)

    {Enum.uniq(signals), mems}
  end

  defp find_assigned_in_statement(%{type: :assign, target: target, value: value}, enable_cond) do
    case target do
      {:mem_write, mem_name, addr_expr} ->
        {[], [{mem_name, addr_expr, value, enable_cond}]}
      target when is_atom(target) ->
        {[target], []}
    end
  end

  defp find_assigned_in_statement(%{type: :if, condition: cond_expr, then_body: then_body, else_body: else_body}, enable_cond) do
    then_enable = {:land, enable_cond, cond_expr}
    {then_sigs, then_mems} = find_all_assigned(then_body, then_enable)

    {else_sigs, else_mems} = if else_body do
      else_enable = {:land, enable_cond, {:lnot, cond_expr}}
      find_all_assigned(else_body, else_enable)
    else
      {[], []}
    end

    {then_sigs ++ else_sigs, then_mems ++ else_mems}
  end

  defp find_assigned_in_statement(%{type: :case, clauses: clauses}, enable_cond) do
    {sigs, mems} = Enum.reduce(clauses, {[], []}, fn %{body: body}, {acc_s, acc_m} ->
      {s, m} = find_all_assigned(body, enable_cond)
      {acc_s ++ s, acc_m ++ m}
    end)
    {sigs, mems}
  end

  defp find_assigned_in_statement(_, _enable_cond), do: {[], []}

  # --- Find All Assignments (for comb blocks) ---

  def find_all_assignments(statements) when is_list(statements) do
    Enum.flat_map(statements, fn
      %{type: :assign, target: target, value: value} -> [{target, value}]
      _ -> []
    end)
  end

  # --- Build Mux Tree ---

  def build_mux_tree(statements, target_name, signal_map, instance_map, memory_map, design, opts \\ []) do
    comb = Keyword.get(opts, :comb, false)
    {value, design} = build_mux_from_statements(statements, target_name, signal_map, instance_map, memory_map, design, comb, nil)
    {value, design}
  end

  # Materialize current_value into an intermediate signal if it's a complex
  # expression (not nil, not already a Signal or Const). This prevents
  # exponential tree duplication when current_value is threaded into multiple
  # branch arms — instead of copying the expression tree N times, each arm
  # gets a reference to the same materialized signal.
  defp materialize(nil, design, _signal_map, _target_name), do: {nil, design}
  defp materialize(%Signal{} = s, design, _signal_map, _target_name), do: {s, design}
  defp materialize(%Const{} = c, design, _signal_map, _target_name), do: {c, design}
  defp materialize(expr, design, signal_map, target_name) do
    target_sig = Map.get(signal_map, target_name)
    width  = if target_sig, do: target_sig.width,  else: 1
    signed = if target_sig, do: target_sig.signed, else: :unsigned
    tmp_name = :"_default_#{target_name}_#{:erlang.unique_integer([:positive])}"
    tmp_sig  = %Signal{name: tmp_name, width: width, signed: signed, direction: :internal}
    d1 = Design.add_signal(design, tmp_sig)
    d2 = Design.add_op(d1, %Hw.IR.Ops.Assign{output: tmp_sig, input: expr})
    {tmp_sig, d2}
  end

  defp build_mux_from_statements(statements, target_name, signal_map, instance_map, memory_map, design, comb, init_value) when is_list(statements) do
    # Look up target signal width so that bare integer constants assigned to this
    # signal get the correct width in mux arms (instead of defaulting to 32-bit).
    target_sig = Map.get(signal_map, target_name)

    # Resolve a const value to the target signal's width when possible.
    fix_const = fn
      %Const{width: 32} = c when target_sig != nil ->
        %Const{c | width: target_sig.width, signed: target_sig.signed}
      other -> other
    end

    # The hold value: what this signal evaluates to if nothing in this scope
    # assigns it. In comb mode, unassigned signals default to 0. In sequential
    # mode, if an outer scope established a value use that, otherwise hold
    # the register's current value.
    hold = fn d ->
      case {comb, init_value} do
        {true,  _}   -> {fix_const.(%Const{value: 0, width: (if target_sig, do: target_sig.width, else: 1), signed: :unsigned}), d}
        {false, nil} -> {fix_const.(Map.fetch!(signal_map, target_name)), d}
        {false, v}   -> {fix_const.(v), d}
      end
    end

    Enum.reduce(statements, {init_value, design}, fn stmt, {current_value, d} ->
      case stmt do
        %{type: :assign, target: ^target_name, value: expr} ->
          {value, d2} = Expr.build_expr(expr, signal_map, instance_map, memory_map, d)
          {fix_const.(value), d2}

        %{type: :if, condition: cond_expr, then_body: then_body, else_body: else_body} ->
          {cond_val, d2} = Expr.build_expr(cond_expr, signal_map, instance_map, memory_map, d)
          # Materialize current_value before branching to avoid duplicating
          # complex expression trees. Only in sequential mode — comb has no
          # carry-forward value and materialization would create comb loops.
          {mat_val, d3} = if comb, do: {nil, d2}, else: materialize(current_value, d2, signal_map, target_name)
          {then_value, d4} = build_mux_from_statements(then_body, target_name, signal_map, instance_map, memory_map, d3, comb, mat_val)
          {else_value, d5} = if else_body do
            build_mux_from_statements(else_body, target_name, signal_map, instance_map, memory_map, d4, comb, mat_val)
          else
            {nil, d4}
          end

          if then_value != nil or else_value != nil do
            {hv, d6} = if mat_val != nil, do: {fix_const.(mat_val), d5}, else: hold.(d5)
            then_val = fix_const.(then_value || hv)
            else_val = fix_const.(else_value || hv)
            {mux_result, d7} = build_mux_op(cond_val, then_val, else_val, d6)
            {mux_result, d7}
          else
            {current_value, d5}
          end

        %{type: :case, expr: case_expr, clauses: clauses} ->
          {case_val, d2} = Expr.build_expr(case_expr, signal_map, instance_map, memory_map, d)
          # Materialize before branching into clauses. Skip in comb mode.
          {mat_val, d3} = if comb, do: {nil, d2}, else: materialize(current_value, d2, signal_map, target_name)

          {case_arms, default_value, d4} = Enum.reduce(clauses, {[], nil, d3}, fn clause, {arms, default_val, acc_d} ->
            %{pattern: pattern, body: body} = clause
            resolved_body = resolve_captures(body, case_val)

            # Each clause body starts from mat_val as its baseline — this is
            # Elixir scoping semantics: outer assignments are visible in clauses
            # that don't reassign the signal.
            {body_value, body_d} = build_mux_from_statements(
              resolved_body, target_name, signal_map, instance_map, memory_map, acc_d, comb, mat_val
            )

            case pattern do
              :default ->
                {arms, body_value, body_d}

              {:binary_pattern, segments, total_width} ->
                {match_sig, match_d} = build_binary_match(case_val, segments, total_width, body_d)
                {arms ++ [{match_sig, body_value}], default_val, match_d}

              _ ->
                {pattern_value, pattern_d} = Expr.build_expr(pattern, signal_map, instance_map, memory_map, body_d)
                {arms ++ [{pattern_value, body_value}], default_val, pattern_d}
            end
          end)

          case_arms = Enum.filter(case_arms, fn {_, v} -> v != nil end)

          if case_arms == [] and default_value == nil do
            {current_value, d4}
          else
            {hv, d5} = if mat_val != nil, do: {fix_const.(mat_val), d4}, else: hold.(d4)
            default_val = fix_const.(default_value || hv)
            case_arms   = Enum.map(case_arms, fn {cond, val} -> {cond, fix_const.(val || hv)} end)
            {case_mux_result, d6} = build_case_mux(case_val, case_arms, default_val, d5)
            {case_mux_result, d6}
          end

        _ ->
          {current_value, d}
      end
    end)
  end

  # --- Binary Pattern Matching ---

  # Resolve :__subject__ placeholder in capture slice expressions with actual subject signal
  defp resolve_captures(body, subject_signal) do
    Enum.map(body, &resolve_captures_in_stmt(&1, subject_signal))
  end

  defp resolve_captures_in_stmt(%{type: :assign, target: _t, value: v} = stmt, subj) do
    %{stmt | value: resolve_captures_in_expr(v, subj)}
  end
  defp resolve_captures_in_stmt(%{type: :if} = stmt, subj) do
    %{stmt |
      condition: resolve_captures_in_expr(stmt.condition, subj),
      then_body: resolve_captures(stmt.then_body, subj),
      else_body: stmt.else_body && resolve_captures(stmt.else_body, subj)
    }
  end
  defp resolve_captures_in_stmt(%{type: :case, clauses: clauses} = stmt, subj) do
    resolved_clauses = Enum.map(clauses, fn clause ->
      %{clause | body: resolve_captures(clause.body, subj)}
    end)
    %{stmt | clauses: resolved_clauses}
  end
  defp resolve_captures_in_stmt(other, _subj), do: other

  defp resolve_captures_in_expr({:slice, {:signal, :__subject__}, hi, lo}, subj) do
    {:slice, subj, {:const, hi}, {:const, lo}}
  end
  defp resolve_captures_in_expr({:slice, inner, hi, lo}, subj) do
    {:slice, resolve_captures_in_expr(inner, subj), hi, lo}
  end
  # 1-arg operators: bnot, unary minus, etc.
  defp resolve_captures_in_expr({op, a}, subj) when is_tuple(a) do
    {op, resolve_captures_in_expr(a, subj)}
  end
  # 2-arg operators
  defp resolve_captures_in_expr({op, a, b}, subj) when is_tuple(a) or is_tuple(b) do
    {op, resolve_captures_in_expr(a, subj), resolve_captures_in_expr(b, subj)}
  end
  # Lists (e.g. concat elements)
  defp resolve_captures_in_expr({:concat, elems}, subj) do
    {:concat, Enum.map(elems, &resolve_captures_in_expr(&1, subj))}
  end
  defp resolve_captures_in_expr(other, _subj), do: other

  # Build a 1-bit "match" signal for a binary pattern against the subject.
  #
  # Strategy: for each literal segment, build an equality check against
  # the corresponding slice of the subject. AND all checks together.
  # Wildcards are simply skipped (don't-care = always match).
  #
  # This is semantically correct and synthesizes identically to casez.
  defp build_binary_match(subject_sig, segments, total_width, design) do
    # Compute bit ranges for each segment (MSB-first)
    {segments_with_ranges, _} = Enum.map_reduce(segments, total_width - 1, fn seg, hi ->
      width = case seg.width do
        :rest -> hi + 1   # rest = all remaining bits
        w -> w
      end
      lo = hi - width + 1
      {{seg, hi, lo}, lo - 1}
    end)

    # Build equality checks for literal segments only
    check_exprs = Enum.flat_map(segments_with_ranges, fn
      {%{type: :literal, value: val, width: w}, hi, lo} ->
        [{:slice_eq, subject_sig, hi, lo, val, w}]
      _ ->
        []   # wildcard and capture: don't-care, skip
    end)

    case check_exprs do
      [] ->
        # All wildcards — always matches — build a constant 1
        result_name = :"_bpmatch_#{:erlang.unique_integer([:positive])}"
        result_sig = %Signal{name: result_name, width: 1, signed: :unsigned, direction: :internal}
        d1 = Design.add_signal(design, result_sig)
        const_one = %Const{value: 1, width: 1, signed: :unsigned}
        d2 = Design.add_op(d1, %Ops.Assign{output: result_sig, input: const_one})
        {result_sig, d2}

      checks ->
        # Build AND-chain of slice equality checks
        Enum.reduce(checks, {nil, design}, fn {:slice_eq, subj, hi, lo, val, w}, {acc_sig, acc_d} ->
          # Extract slice
          slice_name = :"_bpslice_#{:erlang.unique_integer([:positive])}"
          slice_sig = %Signal{name: slice_name, width: hi - lo + 1, signed: :unsigned, direction: :internal}
          hi_const = %Const{value: hi, width: 32, signed: :unsigned}
          lo_const = %Const{value: lo, width: 32, signed: :unsigned}
          acc_d1 = Design.add_signal(acc_d, slice_sig)
          acc_d2 = Design.add_op(acc_d1, %Ops.Slice{output: slice_sig, input: subj, hi: hi_const, lo: lo_const})

          # Equality check
          val_const = %Const{value: val, width: w, signed: :unsigned}
          eq_name = :"_bpeq_#{:erlang.unique_integer([:positive])}"
          eq_sig = %Signal{name: eq_name, width: 1, signed: :unsigned, direction: :internal}
          acc_d3 = Design.add_signal(acc_d2, eq_sig)
          acc_d4 = Design.add_op(acc_d3, %Ops.Eq{output: eq_sig, a: slice_sig, b: val_const})

          # AND with accumulator
          case acc_sig do
            nil ->
              {eq_sig, acc_d4}
            prev ->
              and_name = :"_bpand_#{:erlang.unique_integer([:positive])}"
              and_sig = %Signal{name: and_name, width: 1, signed: :unsigned, direction: :internal}
              acc_d5 = Design.add_signal(acc_d4, and_sig)
              acc_d6 = Design.add_op(acc_d5, %Ops.BitAnd{output: and_sig, a: prev, b: eq_sig})
              {and_sig, acc_d6}
          end
        end)
    end
  end

  defp build_mux_op(condition, then_value, else_value, design) do
    {then_val, else_val} = Expr.match_const_widths(then_value, else_value)

    result_name = :"_mux_#{:erlang.unique_integer([:positive])}"
    width = Expr.infer_width(then_val, else_val)
    signed = Expr.infer_signedness(then_val, else_val)

    result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}

    then_val = Expr.match_value_to_output(then_val, result_sig)
    else_val = Expr.match_value_to_output(else_val, result_sig)

    d1 = Design.add_signal(design, result_sig)

    mux_op = %Ops.Mux{
      output: result_sig,
      cases: [{condition, then_val}],
      default: else_val
    }
    d2 = Design.add_op(d1, mux_op)

    {result_sig, d2}
  end

  defp infer_result_width_signed(vals) do
    # Prefer Signal width/signedness over Const — Signals have declared widths
    Enum.find_value(vals, fn
      %Signal{width: w, signed: s} -> {w, s}
      _ -> nil
    end) || case hd(vals) do
      %Signal{width: w, signed: s} -> {w, s}
      %Const{width: w, signed: s}  -> {w, s}
    end
  end

  defp build_case_mux(case_expr, case_arms, default_val, design) do
    all_vals = Enum.map(case_arms, &elem(&1, 1)) ++ [default_val]
    {width, signed} = infer_result_width_signed(all_vals)

    result_name = :"_case_#{:erlang.unique_integer([:positive])}"

    result_sig = %Signal{name: result_name, width: width, signed: signed, direction: :internal}

    # case_arms entries are already condition signals (either equality or binary match)
    # Binary pattern arms already have pre-built 1-bit match signals
    # Plain equality arms still need comparison signals built
    {cases, d1} = Enum.reduce(case_arms, {[], design}, fn {pattern_or_cond, value}, {acc_cases, acc_d} ->
      # If the pattern is already a 1-bit Signal (from binary pattern matching),
      # use it directly as the condition. Otherwise build equality comparison.
      cond_sig = case pattern_or_cond do
        %Signal{width: 1} = sig -> {sig, acc_d}
        other ->
          cmp_name = :"_eq_#{:erlang.unique_integer([:positive])}"
          cmp_sig = %Signal{name: cmp_name, width: 1, signed: :unsigned, direction: :internal}
          acc_d2 = Design.add_signal(acc_d, cmp_sig)
          eq_op = %Ops.Eq{output: cmp_sig, a: case_expr, b: other}
          acc_d3 = Design.add_op(acc_d2, eq_op)
          {cmp_sig, acc_d3}
      end

      {cond_sig_val, updated_d} = cond_sig
      matched_value = Expr.match_value_to_output(value, result_sig)
      {acc_cases ++ [{cond_sig_val, matched_value}], updated_d}
    end)

    d2 = Design.add_signal(d1, result_sig)
    matched_default = Expr.match_value_to_output(default_val, result_sig)

    mux_op = %Ops.Mux{
      output: result_sig,
      cases: cases,
      default: matched_default
    }
    d3 = Design.add_op(d2, mux_op)

    {result_sig, d3}
  end

  # --- Extract Reset ---

  def extract_reset(statements, target_name, signal_map, const_wire_map \\ %{}) do
    case statements do
      [%{type: :if, condition: {:signal, rst_name}, then_body: then_body} | _]
        when rst_name in [:rst, :reset] ->
        case find_const_assignment(then_body, target_name, const_wire_map) do
          {:ok, const_value} ->
            {build_const(const_value, signal_map, target_name), nil}
          :not_found ->
            {nil, nil}
        end
      _ ->
        {nil, nil}
    end
  end

  defp find_const_assignment(statements, target_name, const_wire_map) do
    Enum.find_value(statements, :not_found, fn
      %{type: :assign, target: ^target_name, value: {:const, n}} ->
        {:ok, n}
      %{type: :assign, target: ^target_name, value: {:signal, sig_name}} ->
        case Map.get(const_wire_map, sig_name) do
          nil -> nil
          n   -> {:ok, n}
        end
      _ ->
        nil
    end)
  end

  defp build_const(value, signal_map, for_signal) do
    sig = Map.fetch!(signal_map, for_signal)
    %Const{value: value, width: sig.width, signed: sig.signed}
  end
end
