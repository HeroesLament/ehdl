defmodule Hw.DSL.Primitives.Parse.Fsm do
  @moduledoc """
  FSM block and statement parsing for EHDL DSL.

  Handles `fsm :state_name do ... end` blocks including:
  - `defaults do ... end` blocks
  - State case bodies with `on condition do ... end` transitions
  - `next :state` unconditional transitions
  - `on :else do ... end` else clauses
  """

  alias Hw.DSL.Primitives.Parse.Expr

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Parse an FSM block. Returns {defaults, states, case_body} where:
  - defaults: list of default assignments (from `defaults do ... end`)
  - states:   list of state atoms extracted from case clauses
  - case_body: the parsed case statement with FSM-aware parsing
  """
  def parse_fsm_block({:__block__, _, statements}, state_name) do
    {defaults, rest} = extract_defaults(statements)
    case_stmt        = find_fsm_case(rest, state_name)
    states           = extract_state_names(case_stmt)
    parsed_case      = parse_fsm_case(case_stmt, state_name)
    {defaults, states, parsed_case}
  end

  def parse_fsm_block(single, state_name) do
    parse_fsm_block({:__block__, [], [single]}, state_name)
  end

  def parse_fsm_statements({:__block__, _, statements}, state_name) do
    Enum.map(statements, &parse_fsm_statement(&1, state_name))
  end
  def parse_fsm_statements(single, state_name) do
    [parse_fsm_statement(single, state_name)]
  end

  # `next :state_name` — unconditional transition
  def parse_fsm_statement({:next, _, [target_state]}, state_name)
      when is_atom(target_state) do
    %{type: :assign, target: state_name, value: {:state, target_state}}
  end

  # `on :else do ... end` — else clause with block
  def parse_fsm_statement({:on, _, [:else, [do: block]]}, state_name) do
    %{type: :fsm_else, body: parse_fsm_statements(block, state_name)}
  end

  # `on :else, do: stmt` — else clause single statement
  def parse_fsm_statement({:on, _, [:else, opts]}, state_name) when is_list(opts) do
    body = Keyword.get(opts, :do)
    %{type: :fsm_else, body: parse_fsm_statements(body, state_name)}
  end

  # `on condition do ... end` — conditional block with FSM-aware body.
  # Body is parsed as FSM statements so `next`, nested `on`, `if`, etc. all work.
  def parse_fsm_statement({:on, _, [condition, [do: block]]}, state_name) do
    %{
      type:      :if,
      condition: Expr.parse_expr(condition),
      then_body: parse_fsm_statements(block, state_name),
      else_body: nil
    }
  end

  # `on condition, next: :state_name` — conditional transition
  def parse_fsm_statement({:on, _, [condition, [next: target_state]]}, state_name) do
    %{
      type:      :if,
      condition: Expr.parse_expr(condition),
      then_body: [%{type: :assign, target: state_name, value: {:state, target_state}}],
      else_body: nil
    }
  end

  # `on condition, next: :state_name, else: ...` — conditional with else
  def parse_fsm_statement({:on, _, [condition, opts]}, state_name) when is_list(opts) do
    target_state = Keyword.get(opts, :next)
    else_body    = Keyword.get(opts, :else)
    %{
      type:      :if,
      condition: Expr.parse_expr(condition),
      then_body: [%{type: :assign, target: state_name, value: {:state, target_state}}],
      else_body: if(else_body, do: parse_fsm_statements(else_body, state_name), else: nil)
    }
  end

  # `if cond do ... else ... end` — FSM-aware conditional.
  # Like `on`, both branches are parsed as FSM statements so a `next` (or nested
  # `if`/`on`) inside either branch produces a real transition. Without this
  # clause a bare `if` fell through to plain statement parsing and any `next`
  # inside it was silently dropped (no transition arc created).
  def parse_fsm_statement({:if, _, [condition, branches]}, state_name)
      when is_list(branches) do
    then_block = Keyword.get(branches, :do)
    else_block = Keyword.get(branches, :else)

    %{
      type:      :if,
      condition: Expr.parse_expr(condition),
      then_body: parse_fsm_statements(then_block, state_name),
      else_body: if(else_block, do: parse_fsm_statements(else_block, state_name), else: nil)
    }
  end

  # NESTED `hdl_case`/`case expr do ... end` inside a state body — FSM-aware.
  # Like `:if`, each clause body is parsed as FSM statements so a `next` inside any
  # clause produces a real transition. Without this a nested hdl_case (e.g. the PHY TX
  # :data state matching on <<tx_se0,tx_valid,tx_data>>) fell through to the plain
  # parser and EVERY `next` inside it was silently DROPPED — the TX FSM could never
  # leave :data. Patterns here are data patterns (bit-vectors / wildcards), not state
  # atoms, so use Expr for the subject and keep the raw pattern AST for matching.
  def parse_fsm_statement({tag, _, [subject, [do: clauses]]}, state_name)
      when tag in [:case, :hdl_case] and is_list(clauses) do
    {subject_expr, subject_segments} =
      Hw.DSL.Primitives.Parse.Binary.parse_case_subject(subject)

    %{
      type:             :case,
      expr:             subject_expr,
      subject_segments: subject_segments,
      clauses:          Enum.map(clauses, &parse_fsm_data_clause(&1, subject_segments, state_name))
    }
  end

  # Regular statements fall through to normal statement parsing
  def parse_fsm_statement(stmt, _state_name) do
    Hw.DSL.Primitives.Parse.parse_statement(stmt)
  end

  # A clause of a nested data hdl_case: parse the pattern via the normal Binary path
  # (bit-vector / wildcard, using the subject segments), but parse the BODY as FSM
  # statements so a `next` inside the clause produces a real transition arc.
  defp parse_fsm_data_clause({:->, _, [[pattern], body]}, subject_segments, state_name) do
    {parsed_pattern, _captures} =
      Hw.DSL.Primitives.Parse.Binary.parse_case_pattern(pattern, subject_segments)

    %{
      pattern: parsed_pattern,
      body:    parse_fsm_statements(body, state_name)
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp extract_defaults(statements) do
    case Enum.split_with(statements, &is_defaults_block?/1) do
      {[], rest}                              -> {[], rest}
      {[{:defaults, _, [[do: block]]}], rest} ->
        {Hw.DSL.Primitives.Parse.parse_statements(block), rest}
      {[{:defaults, _, [block]}], rest}       ->
        {Hw.DSL.Primitives.Parse.parse_statements(block), rest}
    end
  end

  defp is_defaults_block?({:defaults, _, _}), do: true
  defp is_defaults_block?(_),                 do: false

  defp find_fsm_case(statements, state_name) do
    Enum.find(statements, fn
      {:case,     _, [{^state_name, _, _}, _]} -> true
      {:hdl_case, _, [{^state_name, _, _}, _]} -> true
      _ -> false
    end) || raise "FSM block must contain `hdl_case #{state_name} do ... end`"
  end

  defp extract_state_names({tag, _, [_, [do: clauses]]}) when tag in [:case, :hdl_case] do
    Enum.map(clauses, fn {:->, _, [[pattern], _]} ->
      case pattern do
        {name, _, _} when is_atom(name) -> name
        name when is_atom(name)         -> name
        _ -> raise "FSM state patterns must be atoms"
      end
    end)
  end

  defp parse_fsm_case({tag, _, [expr, [do: clauses]]}, state_name)
       when tag in [:case, :hdl_case] do
    %{
      type:             :case,
      expr:             Expr.parse_expr(expr),
      subject_segments: nil,
      clauses:          Enum.map(clauses, &parse_fsm_clause(&1, state_name))
    }
  end

  defp parse_fsm_clause({:->, _, [[pattern], body]}, state_name) do
    %{
      pattern: parse_fsm_pattern(pattern),
      body:    parse_fsm_statements(body, state_name)
    }
  end

  defp parse_fsm_pattern({name, _, _}) when is_atom(name), do: {:state, name}
  defp parse_fsm_pattern(name)         when is_atom(name), do: {:state, name}
end
