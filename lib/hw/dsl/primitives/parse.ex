defmodule Hw.DSL.Primitives.Parse do
  @moduledoc """
  Expression and statement parsing for DSL blocks.

  Delegates expression parsing to `Parse.Expr`, binary pattern parsing to
  `Parse.Binary`, and FSM parsing to `Parse.Fsm`. This module owns the
  statement-level dispatcher and the entry points used by logic_blocks.ex macros.

  ## `on condition do` in defhw bodies

  Inside `defhw`, `on condition do ... end` is a simulation-only wait construct.
  It produces `%{type: :on_condition, condition: ..., body: [...]}` in the IR,
  which the `DefhwInterpreter` handles by ticking the clock until condition is
  true before executing the body. Hardware elaboration ignores these nodes.
  """

  alias Hw.DSL.Primitives.Parse.{Expr, Binary, Fsm}

  # ---------------------------------------------------------------------------
  # Entry points
  # ---------------------------------------------------------------------------

  def parse_on_block(block),   do: parse_statements(block)
  def parse_comb_block(block), do: parse_statements(block)

  def parse_statements({:__block__, _, statements}) do
    Enum.flat_map(statements, &splice(parse_statement(&1)))
  end
  def parse_statements(single), do: splice(parse_statement(single))

  # A statement-level `generate` parses to its unrolled copies.
  defp splice(%{type: :generate_splice, body: body}), do: body
  defp splice(stmt), do: [stmt]

  # ---------------------------------------------------------------------------
  # Statement parsing
  # ---------------------------------------------------------------------------

  def parse_statement({:if, _, [condition, branches]}) do
    %{
      type:      :if,
      condition: parse_expr(condition),
      then_body: parse_statements(Keyword.get(branches, :do)),
      else_body: if(eb = Keyword.get(branches, :else), do: parse_statements(eb), else: nil)
    }
  end

  # hdl_case: identical to case but subject <<>> arrives un-expanded.
  def parse_statement({:hdl_case, _, [expr, [do: clauses]]}) do
    parse_statement({:case, [], [expr, [do: clauses]]})
  end

  def parse_statement({:case, _, [expr, [do: clauses]]}) do
    {real_expr, real_clauses} = case expr do
      {key, _, nil} when is_atom(key) ->
        case Process.get(key) do
          {subj, cls} -> {subj, cls}
          nil         -> {expr, clauses}
        end
      _ ->
        {expr, clauses}
    end

    {parsed_expr, subject_segments} = Binary.parse_case_subject(real_expr)

    %{
      type:             :case,
      expr:             parsed_expr,
      subject_segments: subject_segments,
      clauses:          Enum.map(real_clauses, &Binary.parse_case_clause(&1, subject_segments))
    }
  end

  def parse_statement({:=, _, [lhs, rhs]}) do
    %{type: :assign, target: parse_target(lhs), value: parse_expr(rhs)}
  end

  # `generate k <- 0..3 do ... end` inside `on`, `comb` or an `if`: unrolled
  # here (`Hw.DSL.Generate`), so the IR holds one copy per index and no trace
  # of the loop. `parse_statements/1` splices the copies in place.
  def parse_statement({:generate, _, [{:<-, _, [{var, _, ctx}, range]}, [do: body]]})
      when is_atom(var) and is_atom(ctx) do
    if Hw.DSL.Generate.declarative?(body) do
      raise ArgumentError,
            "generate inside a logic block may hold statements only; declare " <>
              "wires and blocks with a module-level generate"
    end

    copies = Hw.DSL.Generate.unroll(var, range, body)
    %{type: :generate_splice, body: Enum.flat_map(copies, &parse_statements/1)}
  end

  def parse_statement({:hold}), do: %{type: :hold}
  def parse_statement(:hold),   do: %{type: :hold}

  # `on condition do ... end` in a defhw body — simulation-only wait construct.
  # Ticks the clock until condition is true, then executes body.
  # Ignored by hardware elaboration (not reachable from on :clk or comb blocks).
  def parse_statement({:on, _, [condition, [do: block]]}) do
    %{
      type:      :on_condition,
      condition: parse_expr(condition),
      body:      parse_statements(block)
    }
  end

  # defhw call in statement position — name(arg1, arg2, ...)
  def parse_statement({name, _, args})
      when is_atom(name) and is_list(args) and
           name not in [:if, :case, :hdl_case, :generate, :next, :on, :defaults,
                        :div, :rem, :min, :max, :abs, :clog2, :and, :or, :not,
                        :==, :!=, :<, :>, :<=, :>=,
                        :reduce_and, :reduce_or, :reduce_xor, :popcount, :parity,
                        :reverse_bits, :sign_extend, :zero_extend, :replicate,
                        :mul_round, :cmul, :cadd, :csub, :cmag_sq, :cconj,
                        :shra, :bnot, :band, :bor, :bxor] do
    %{
      type: :defhw_call,
      name: name,
      args: Enum.map(args, &parse_expr/1)
    }
  end

  def parse_statement({:<=, _, [lhs, _rhs]}) do
    name = case lhs do
      {n, _, nil} when is_atom(n) -> n
      _ -> inspect(lhs)
    end
    raise ArgumentError,
      "`#{name} <= ...` is not valid — EHDL uses `=` for all assignments " <>
      "(both combinational and sequential). Use `#{name} = ...` instead."
  end

  def parse_statement({:==, _, [{:<=, _, [lhs, _rhs]}, _rest]}) do
    name = case lhs do
      {n, _, nil} when is_atom(n) -> n
      _ -> inspect(lhs)
    end
    raise ArgumentError,
      "`#{name} <= ...` is not valid — EHDL uses `=` for all assignments. " <>
      "Use `#{name} = (expr == value)` instead."
  end

  def parse_statement({op, _, [{:<=, _, [lhs, _rhs]}, _rest]}) when op in [:or, :and] do
    name = case lhs do
      {n, _, nil} when is_atom(n) -> n
      _ -> inspect(lhs)
    end
    raise ArgumentError,
      "`#{name} <= ...` is not valid — EHDL uses `=` for all assignments. " <>
      "Use `#{name} = (expr #{op} value)` instead."
  end

  def parse_statement(other), do: %{type: :unknown, ast: other}

  # ---------------------------------------------------------------------------
  # Target parsing
  # ---------------------------------------------------------------------------

  def parse_target({name, _, nil}) when is_atom(name), do: name
  def parse_target({name, _, _})   when is_atom(name), do: name
  def parse_target(name)           when is_atom(name), do: name
  def parse_target({{:., _, [Access, :get]}, _, [{mem, _, nil}, addr]}) when is_atom(mem) do
    {:mem_write, mem, parse_expr(addr)}
  end

  # ---------------------------------------------------------------------------
  # Delegation to submodules
  # ---------------------------------------------------------------------------

  defdelegate parse_expr(ast),                         to: Expr
  defdelegate parse_fsm_block(block, state_name),      to: Fsm
  defdelegate parse_fsm_statements(block, state_name), to: Fsm
  defdelegate parse_fsm_statement(stmt, state_name),   to: Fsm
end
