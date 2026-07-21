defmodule Hw.DSL.Primitives.Parse.Expr do
  @moduledoc """
  Expression parsing for EHDL DSL blocks.

  Converts raw Elixir AST nodes into EHDL IR expression tuples consumed by
  the elaborator. All operators, literals, signal references, slices, and
  defhw call expressions are handled here.
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  # Hardware capture marker injected during binary pattern body parsing
  def parse_expr({:__hw_capture__, slice_expr}), do: slice_expr

  # Instance signal: inst.signal or inst[:signal]
  def parse_expr({{:., _, [Access, :get]}, _, [{inst, _, nil}, sig]})
      when is_atom(inst) and is_atom(sig) do
    {:instance_signal, inst, sig}
  end
  def parse_expr({{:., _, [{inst, _, nil}, sig]}, _, []})
      when is_atom(inst) and is_atom(sig) do
    {:instance_signal, inst, sig}
  end

  # Signal reference — nil context (variable) or Elixir context (from quote)
  def parse_expr({name, _, ctx})
      when is_atom(name) and (ctx == nil or ctx == Elixir) do
    {:signal, name}
  end

  # Uppercase identifiers (param refs) come through as __aliases__
  def parse_expr({:__aliases__, _, [name]}) when is_atom(name), do: {:signal, name}

  # Constants
  def parse_expr(:z),                     do: {:const_z}
  def parse_expr(:Z),                     do: {:const_z}
  def parse_expr(:high_z),               do: {:const_z}
  def parse_expr(n) when is_integer(n),  do: {:const, n}

  # Case expression (RHS) — lower to nested ternaries at parse time
  def parse_expr({:case, _, [subject, [do: clauses]]}) do
    parse_case_as_ternary(parse_expr(subject), clauses)
  end

  # Binary literal concat: <<sig_a::8, sig_b::8>> in expression context
  def parse_expr({:<<>>, _, segments}) do
    parsed = Enum.map(segments, &Hw.DSL.Primitives.Parse.Binary.parse_binary_segment_subject/1)
    {:concat, Enum.map(parsed, &binary_segment_to_expr/1)}
  end

  # Arithmetic
  def parse_expr({:+,   _, [a, b]}), do: {:add,  parse_expr(a), parse_expr(b)}
  def parse_expr({:-,   _, [a, b]}), do: {:sub,  parse_expr(a), parse_expr(b)}
  def parse_expr({:-,   _, [a]}),    do: {:neg,  parse_expr(a)}
  def parse_expr({:*,   _, [a, b]}), do: {:mul,  parse_expr(a), parse_expr(b)}
  def parse_expr({:div, _, [a, b]}), do: {:div,  parse_expr(a), parse_expr(b)}
  def parse_expr({:/,   _, [a, b]}), do: {:div,  parse_expr(a), parse_expr(b)}
  def parse_expr({:rem, _, [a, b]}), do: {:mod,  parse_expr(a), parse_expr(b)}

  # Bitwise
  def parse_expr({:&&&,  _, [a, b]}), do: {:band,  parse_expr(a), parse_expr(b)}
  def parse_expr({:&,    _, [a, b]}), do: {:band,  parse_expr(a), parse_expr(b)}
  def parse_expr({:band, _, [a, b]}), do: {:band,  parse_expr(a), parse_expr(b)}
  def parse_expr({:|||,  _, [a, b]}), do: {:bor,   parse_expr(a), parse_expr(b)}
  def parse_expr({:|,    _, [a, b]}), do: {:bor,   parse_expr(a), parse_expr(b)}
  def parse_expr({:bor,  _, [a, b]}), do: {:bor,   parse_expr(a), parse_expr(b)}
  def parse_expr({:^^^,  _, [a, b]}), do: {:bxor,  parse_expr(a), parse_expr(b)}
  def parse_expr({:^,    _, [a, b]}), do: {:bxor,  parse_expr(a), parse_expr(b)}
  def parse_expr({:bxor, _, [a, b]}), do: {:bxor,  parse_expr(a), parse_expr(b)}
  def parse_expr({:~~~,  _, [a]}),    do: {:bnot,  parse_expr(a)}
  def parse_expr({:bnot, _, [a]}),    do: {:bnot,  parse_expr(a)}

  # Shifts
  def parse_expr({:<<<,  _, [a, b]}), do: {:shl,  parse_expr(a), parse_expr(b)}
  def parse_expr({:>>>,  _, [a, b]}), do: {:shr,  parse_expr(a), parse_expr(b)}
  def parse_expr({:shra, _, [a, b]}), do: {:shra, parse_expr(a), parse_expr(b)}

  # Comparison
  def parse_expr({:==, _, [a, b]}), do: {:eq,  parse_expr(a), parse_expr(b)}
  def parse_expr({:!=, _, [a, b]}), do: {:neq, parse_expr(a), parse_expr(b)}
  def parse_expr({:<,  _, [a, b]}), do: {:lt,  parse_expr(a), parse_expr(b)}
  def parse_expr({:>,  _, [a, b]}), do: {:gt,  parse_expr(a), parse_expr(b)}
  def parse_expr({:<=, _, [a, b]}), do: {:lte, parse_expr(a), parse_expr(b)}
  def parse_expr({:>=, _, [a, b]}), do: {:gte, parse_expr(a), parse_expr(b)}

  # Logical
  def parse_expr({:and, _, [a, b]}), do: {:land, parse_expr(a), parse_expr(b)}
  def parse_expr({:or,  _, [a, b]}), do: {:lor,  parse_expr(a), parse_expr(b)}
  def parse_expr({:not, _, [a]}),    do: {:lnot, parse_expr(a)}

  # Reduction
  def parse_expr({:reduce_and, _, [a]}), do: {:reduce_and, parse_expr(a)}
  def parse_expr({:reduce_or,  _, [a]}), do: {:reduce_or,  parse_expr(a)}
  def parse_expr({:reduce_xor, _, [a]}), do: {:reduce_xor, parse_expr(a)}

  # Bit manipulation
  def parse_expr({:popcount,    _, [a]}),        do: {:popcount,    parse_expr(a)}
  def parse_expr({:parity,      _, [a]}),        do: {:reduce_xor,  parse_expr(a)}
  def parse_expr({:reverse_bits,_, [a]}),        do: {:reverse_bits,parse_expr(a)}
  def parse_expr({:sign_extend, _, [a, width]}), do: {:sign_extend, parse_expr(a), width}
  def parse_expr({:zero_extend, _, [a, width]}), do: {:zero_extend, parse_expr(a), width}

  # Arithmetic helpers
  def parse_expr({:abs,   _, [a]}),    do: {:abs,   parse_expr(a)}
  def parse_expr({:min,   _, [a, b]}), do: {:min,   parse_expr(a), parse_expr(b)}
  def parse_expr({:max,   _, [a, b]}), do: {:max,   parse_expr(a), parse_expr(b)}
  def parse_expr({:clog2, _, [a]}),    do: {:clog2, parse_expr(a)}

  # DSP helpers
  def parse_expr({:mul_round, _, [a, b, shift]}) do
    {:mul_round, parse_expr(a), parse_expr(b), shift}
  end

  # Complex operations
  def parse_expr({:cmul,   _, [a, b]}), do: {:cmul,   extract_name(a), extract_name(b)}
  def parse_expr({:cadd,   _, [a, b]}), do: {:cadd,   extract_name(a), extract_name(b)}
  def parse_expr({:csub,   _, [a, b]}), do: {:csub,   extract_name(a), extract_name(b)}
  def parse_expr({:cmag_sq,_, [a]}),    do: {:cmag_sq,extract_name(a)}
  def parse_expr({:cconj,  _, [a]}),    do: {:cconj,  extract_name(a)}

  # Replicate
  def parse_expr({:replicate, _, [a, n]}) when is_integer(n) do
    {:replicate, parse_expr(a), n}
  end

  # Ternary
  def parse_expr({:if, _, [cond, [do: then_val, else: else_val]]}) do
    {:ternary, parse_expr(cond), parse_expr(then_val), parse_expr(else_val)}
  end

  # Tuple/concatenation
  def parse_expr({:{}, _, elements}), do: {:concat, Enum.map(elements, &parse_expr/1)}
  def parse_expr({a, b}),             do: {:concat, [parse_expr(a), parse_expr(b)]}

  # Bit slice: signal[high..low]
  def parse_expr({{:., _, [Access, :get]}, _, [base, {:"..", _, [high, low]}]}) do
    {:slice, parse_expr(base), parse_expr(high), parse_expr(low)}
  end

  # Memory/index: name[index]
  def parse_expr({{:., _, [Access, :get]}, _, [{name, _, nil}, index]})
      when is_atom(name) do
    {:mem_or_index, name, parse_expr(index)}
  end
  def parse_expr({{:., _, [Access, :get]}, _, [base, index]}) do
    {:index, parse_expr(base), parse_expr(index)}
  end
  def parse_expr({:Access, _, [base, index]}) do
    {:index, parse_expr(base), parse_expr(index)}
  end

  # defhw call in expression position — name(arg1, arg2, ...)
  # All DSL builtins, operators, and special forms excluded.
  def parse_expr({name, _, args})
      when is_atom(name) and is_list(args) and
           name not in [:if, :case, :hdl_case, :div, :rem, :min, :max, :abs, :clog2,
                        :and, :or, :not, :==, :!=, :<, :>, :<=, :>=,
                        :reduce_and, :reduce_or, :reduce_xor, :popcount, :parity,
                        :reverse_bits, :sign_extend, :zero_extend, :replicate,
                        :mul_round, :cmul, :cadd, :csub, :cmag_sq, :cconj,
                        :shra, :bnot, :band, :bor, :bxor] do
    %{defhw_call: name, args: Enum.map(args, &parse_expr/1)}
  end

  # Fallback
  def parse_expr(other), do: {:unknown, other}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def extract_name({name, _, nil}) when is_atom(name), do: name
  def extract_name({name, _, _})   when is_atom(name), do: name
  def extract_name(name)           when is_atom(name), do: name

  defp binary_segment_to_expr(%{expr: nil}) do
    raise "Wildcard `_` segment not valid in expression context (only in patterns)"
  end
  defp binary_segment_to_expr(%{expr: expr}), do: expr

  # Lower case expression to nested ternaries.
  # case x do 0 -> a; 1 -> b; _ -> c end
  # becomes: ternary(x==0, a, ternary(x==1, b, c))
  def parse_case_as_ternary(subject_expr, clauses) do
    clauses
    |> Enum.reverse()
    |> Enum.reduce(nil, fn {:->, _, [[pattern], body]}, acc ->
      body_expr = parse_expr(body)
      case pattern do
        {:_, _, _} ->
          body_expr
        _ ->
          cond_expr = {:eq, subject_expr, parse_expr(pattern)}
          else_expr = acc || body_expr
          {:ternary, cond_expr, body_expr, else_expr}
      end
    end)
  end
end
