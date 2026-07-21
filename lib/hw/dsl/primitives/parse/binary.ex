defmodule Hw.DSL.Primitives.Parse.Binary do
  @moduledoc """
  Binary pattern parsing for `hdl_case` subjects and patterns.

  Handles `<<signal::width>>` syntax in both subject position (concatenating
  signals into a match value) and pattern position (producing bit-precise
  match conditions and named captures).

  Named captures in patterns resolve to slice expressions on the subject,
  making them available as pseudo-signals in the clause body.
  """

  alias Hw.DSL.Primitives.Parse.Expr

  # ---------------------------------------------------------------------------
  # Subject parsing
  # ---------------------------------------------------------------------------

  # <<>> subject — concatenates signals, produces subject_segments for pattern matching
  def parse_case_subject({:<<>>, _, segments}) do
    parsed_segs  = Enum.map(segments, &parse_binary_segment_subject/1)
    concat_exprs = Enum.map(parsed_segs, fn seg -> seg.expr end)
    {{:concat, concat_exprs}, parsed_segs}
  end

  # Plain signal/expression subject — no binary pattern magic
  def parse_case_subject(other) do
    {Expr.parse_expr(other), nil}
  end

  # ---------------------------------------------------------------------------
  # Clause/pattern parsing (called from Parse)
  # ---------------------------------------------------------------------------

  def parse_case_clause({:->, _, [[pattern], body]}, subject_segments) do
    {parsed_pattern, captures} = parse_case_pattern(pattern, subject_segments)
    parsed_body = parse_statements_with_captures(body, captures)
    %{pattern: parsed_pattern, body: parsed_body}
  end

  # ---------------------------------------------------------------------------
  # Case pattern parsing
  # ---------------------------------------------------------------------------

  # Wildcard pattern — matches everything, no captures
  def parse_case_pattern({:_, _, _}, _subject_segments) do
    {:default, %{}}
  end

  # Binary pattern — only valid when subject also has segments
  def parse_case_pattern({:<<>>, _, pattern_segments}, subject_segments)
      when not is_nil(subject_segments) do
    parsed_segs   = Enum.map(pattern_segments, &parse_binary_segment_pattern/1)
    subject_width = total_width(subject_segments)
    pattern_width = total_width(parsed_segs)

    if pattern_width != subject_width and pattern_width != :rest do
      raise Hw.Compile.Elaborate.ElabError,
        message: "Binary pattern width #{inspect(pattern_width)} doesn't match " <>
                 "subject width #{inspect(subject_width)}",
        context: pattern_segments
    end

    captures = build_capture_map(parsed_segs, subject_width)
    {build_binary_pattern(parsed_segs, subject_width), captures}
  end

  # Plain expression pattern (integer literal, atom, etc.) — no captures
  def parse_case_pattern(other, _subject_segments) do
    {Expr.parse_expr(other), %{}}
  end

  # ---------------------------------------------------------------------------
  # Binary segment parsing — subjects
  # ---------------------------------------------------------------------------

  def parse_binary_segment_subject({:"::", _, [value, width]})
      when is_integer(value) and is_integer(width) do
    %{type: :literal, value: value, width: width, expr: {:const, value}}
  end

  def parse_binary_segment_subject({:"::", _, [{:_, _, _}, {rest, _, _}]})
      when rest in [:binary, :bits] do
    %{type: :wildcard, width: :rest, expr: nil}
  end

  def parse_binary_segment_subject({:"::", _, [{:_, _, _}, width]})
      when is_integer(width) do
    %{type: :wildcard, width: width, expr: nil}
  end

  def parse_binary_segment_subject({:"::", _, [{name, _, _ctx}, width]})
      when is_atom(name) and name != :_ and is_integer(width) do
    %{type: :signal_seg, name: name, width: width, expr: {:signal, name}}
  end

  # ---------------------------------------------------------------------------
  # Binary segment parsing — patterns
  # ---------------------------------------------------------------------------

  def parse_binary_segment_pattern({:"::", _, [value, width]})
      when is_integer(value) and is_integer(width) do
    %{type: :literal, value: value, width: width, expr: {:const, value}}
  end

  def parse_binary_segment_pattern({:"::", _, [{:_, _, _}, {rest, _, _}]})
      when rest in [:binary, :bits] do
    %{type: :wildcard, width: :rest, expr: nil}
  end

  def parse_binary_segment_pattern({:"::", _, [{:_, _, _}, width]})
      when is_integer(width) do
    %{type: :wildcard, width: width, expr: nil}
  end

  def parse_binary_segment_pattern({:"::", _, [{name, _, _ctx}, width]})
      when is_atom(name) and name != :_ and is_integer(width) do
    %{type: :capture, name: name, width: width, expr: {:signal, name}}
  end

  # ---------------------------------------------------------------------------
  # Binary pattern IR construction
  # ---------------------------------------------------------------------------

  def build_binary_pattern(segments, total_width) do
    {:binary_pattern, segments, total_width}
  end

  # Build capture map: name -> {:slice, :__subject__, hi, lo}
  # :__subject__ is a placeholder resolved by the elaborator to the actual subject.
  # Only :capture type segments (from pattern arms) are added — not :signal_seg
  # segments (from subjects).
  def build_capture_map(segments, total_width) do
    {captures, _pos} = Enum.reduce(segments, {%{}, total_width - 1}, fn seg, {caps, hi} ->
      width    = seg.width
      lo       = hi - width + 1
      new_caps = case seg do
        %{type: :capture, name: name} ->
          Map.put(caps, name, {:slice, {:signal, :__subject__}, hi, lo})
        _ ->
          caps
      end
      {new_caps, lo - 1}
    end)
    captures
  end

  def total_width(segments) do
    Enum.reduce(segments, 0, fn
      %{width: :rest}, _acc -> :rest
      %{width: w},     acc  -> acc + w
    end)
  end

  # ---------------------------------------------------------------------------
  # Capture-aware statement parsing (used by parse_case_clause)
  # ---------------------------------------------------------------------------

  def parse_statements_with_captures(body, captures) when map_size(captures) == 0 do
    Hw.DSL.Primitives.Parse.parse_statements(body)
  end
  def parse_statements_with_captures(body, captures) do
    parse_statements_with_capture_scope(body, captures)
  end

  defp parse_statements_with_capture_scope({:__block__, _, statements}, captures) do
    Enum.map(statements, &parse_statement_with_captures(&1, captures))
  end
  defp parse_statements_with_capture_scope(single, captures) do
    [parse_statement_with_captures(single, captures)]
  end

  defp parse_statement_with_captures({:=, _, [lhs, rhs]}, captures) do
    %{type:   :assign,
      target: Hw.DSL.Primitives.Parse.parse_target(lhs),
      value:  parse_expr_with_captures(rhs, captures)}
  end
  defp parse_statement_with_captures({:if, _, [cond, branches]}, captures) do
    %{
      type:      :if,
      condition: parse_expr_with_captures(cond, captures),
      then_body: parse_statements_with_capture_scope(Keyword.get(branches, :do), captures),
      else_body: if(eb = Keyword.get(branches, :else),
                   do: parse_statements_with_capture_scope(eb, captures),
                   else: nil)
    }
  end
  defp parse_statement_with_captures(other, _captures) do
    Hw.DSL.Primitives.Parse.parse_statement(other)
  end

  defp parse_expr_with_captures({name, _, ctx}, captures)
       when is_atom(name) and (ctx == nil or ctx == Elixir) do
    case Map.get(captures, name) do
      nil   -> Expr.parse_expr({name, [], nil})
      slice -> slice
    end
  end
  defp parse_expr_with_captures({op, meta, args}, captures) when is_list(args) do
    rewritten = {op, meta, Enum.map(args, &rewrite_captures(&1, captures))}
    Expr.parse_expr(rewritten)
  end
  defp parse_expr_with_captures(other, _captures), do: Expr.parse_expr(other)

  defp rewrite_captures({name, meta, ctx}, captures)
       when is_atom(name) and (ctx == nil or ctx == Elixir) do
    case Map.get(captures, name) do
      nil   -> {name, meta, nil}
      slice -> {:__hw_capture__, slice}
    end
  end
  defp rewrite_captures({op, meta, args}, captures) when is_list(args) do
    {op, meta, Enum.map(args, &rewrite_captures(&1, captures))}
  end
  defp rewrite_captures(other, _captures), do: other
end
