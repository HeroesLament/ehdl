defmodule Hw.Compile.Validate do
  @moduledoc """
  Validation rules for hardware IR.

  This module enforces all invariants that make hardware correct.
  Validation errors are fatal - there is no recovery, no warnings.

  ## Philosophy

  If something is wrong, fail early and loudly.
  The point is to catch bugs at elaboration time, not simulation time.
  """

  alias Hw.IR.Design
  alias Hw.IR.Types.{Signal, Const}
  alias Hw.IR.Ops.{Reg, Add, Sub, Mux, Cast, Assign, BitAnd, BitOr, Eq}
  alias Hw.IR.Types.Clock

  defmodule Error do
    @moduledoc "Structured validation error"
    defexception [:message, :op, :details]

    @impl true
    def message(%{message: msg, details: nil}),     do: msg
    def message(%{message: msg, details: details}), do: "#{msg}: #{inspect(details)}"
  end

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Validate an entire design. Returns `{:ok, design}` or `{:error, errors}`.
  """
  def validate(%Design{} = design) do
    errors =
      []
      |> check_signal_references(design)
      |> check_clock_references(design)
      |> check_signedness(design)
      |> check_widths(design)
      |> check_single_driver(design)
      |> check_registers_have_clocks(design)
      |> check_cdc_crossings(design)

    case errors do
      []     -> {:ok, design}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Validate and raise on first error. Renders a diagnostic before raising.
  """
  def validate!(%Design{} = design) do
    case validate(design) do
      {:ok, design} ->
        design
      {:error, [first | rest]} ->
        render_diagnostic(first)
        if rest != [] do
          IO.puts("  (#{length(rest)} additional error(s) suppressed)\n")
        end
        raise first
    end
  end

  # ── Diagnostic Rendering ───────────────────────────────────────────────────

  defp render_diagnostic(%Error{} = err) do
    Hw.Diagnostic.error(
      code:    error_code(err),
      message: err.message,
      notes:   error_notes(err),
      hint:    error_hint(err)
    )
  end

  # Error codes
  defp error_code(%Error{message: "Mux value width" <> _}),           do: "E031"
  defp error_code(%Error{message: "Width mismatch in arithmetic" <> _}), do: "E032"
  defp error_code(%Error{message: "Signedness mismatch" <> _}),       do: "E033"
  defp error_code(%Error{message: "Unknown signal referenced" <> _}), do: "E010"
  defp error_code(%Error{message: "Unknown clock referenced" <> _}),  do: "E011"
  defp error_code(%Error{message: "Multiple drivers" <> _}),          do: "E020"
  defp error_code(%Error{message: "Register without clock" <> _}),    do: "E021"
  defp error_code(%Error{message: "Unsafe clock domain" <> _}),       do: "E040"
  defp error_code(_),                                                  do: "E000"

  # ── Notes per error type ───────────────────────────────────────────────────

  defp error_notes(%Error{op: %Mux{output: out, cases: cases, default: default}}) do
    out_width = out.width

    # Find the mismatched value
    all_values = [default | Enum.map(cases, &elem(&1, 1))]
    mismatched = Enum.find(all_values, fn val ->
      w = get_width(val)
      w != nil and w != out_width
    end)

    val_width = get_width(mismatched) || "?"
    val_name  = signal_name(mismatched)

    notes = ["signal `#{out.name}` has declared width #{out_width}"]
    notes = if val_name do
      notes ++ ["`#{val_name}` has width #{val_width} — widths must match"]
    else
      notes ++ ["mux value has width #{val_width} — widths must match"]
    end
    notes
  end

  defp error_notes(%Error{op: %Add{output: out, a: a, b: b}}) do
    [
      "output `#{out.name}` width #{out.width}",
      "operand widths: #{get_width(a) || "?"} vs #{get_width(b) || "?"}"
    ]
  end

  defp error_notes(%Error{op: %Sub{output: out, a: a, b: b}}) do
    [
      "output `#{out.name}` width #{out.width}",
      "operand widths: #{get_width(a) || "?"} vs #{get_width(b) || "?"}"
    ]
  end

  defp error_notes(%Error{message: "Unknown signal referenced", details: name}) do
    ["signal `#{name}` is used but was never declared"]
  end

  defp error_notes(%Error{message: "Unknown clock referenced", details: name}) do
    ["clock `#{name}` is used but was never declared"]
  end

  defp error_notes(%Error{message: "Multiple drivers for signal", details: %{signal: name, count: n}}) do
    ["signal `#{name}` is driven by #{n} sources — only one driver allowed"]
  end

  defp error_notes(%Error{op: %Reg{output: out}}) do
    ["register `#{out.name}` has no clock assigned"]
  end

  defp error_notes(%Error{details: %{signal: sig, src_domain: src, dst_domain: dst}}) do
    [
      "`#{sig}` is produced in clock domain `#{src}`",
      "consumed in clock domain `#{dst}` without a synchronizer"
    ]
  end

  defp error_notes(_), do: []

  # ── Hints per error type ───────────────────────────────────────────────────

  defp error_hint(%Error{op: %Mux{output: out}}) do
    "declare an explicit width for signals feeding `#{out.name}`, " <>
    "e.g. `wire :signal_name, #{out.width}`"
  end

  defp error_hint(%Error{message: "Signedness mismatch" <> _}) do
    "use `sign_extend/2` or `zero_extend/2` to align signedness before the operation"
  end

  defp error_hint(%Error{message: "Width mismatch in arithmetic" <> _}) do
    "use `zero_extend/2` or a bit slice `signal[n..0]` to align widths"
  end

  defp error_hint(%Error{message: "Multiple drivers" <> _, details: %{signal: name}}) do
    "ensure `#{name}` is assigned in only one `comb do` or `on :clk do` block"
  end

  defp error_hint(%Error{message: "Unsafe clock domain" <> _, details: %{signal: sig, dst_domain: dst}}) do
    "add a synchronizer:\n" <>
    "    instance :sync_#{sig}, Hw.CDC.Sync2,\n" <>
    "      clk_dst: :#{dst}, data_in: :#{sig}, data_out: :#{sig}_sync"
  end

  defp error_hint(_), do: nil

  # ── Signal Reference Checks ────────────────────────────────────────────────

  defp check_signal_references(errors, %Design{signals: signals, ops: ops}) do
    known_signals = MapSet.new(signals, & &1.name)

    Enum.reduce(ops, errors, fn op, acc ->
      referenced = get_signal_refs(op)

      Enum.reduce(referenced, acc, fn name, acc2 ->
        if MapSet.member?(known_signals, name) do
          acc2
        else
          [%Error{message: "Unknown signal referenced", op: op, details: name} | acc2]
        end
      end)
    end)
  end

  defp get_signal_refs(%Reg{output: out, input: inp, enable: en}) do
    refs = [out.name | value_refs(inp)]
    if en, do: [en.name | refs], else: refs
  end
  defp get_signal_refs(%Add{output: out, a: a, b: b}) do
    [out.name | value_refs(a) ++ value_refs(b)]
  end
  defp get_signal_refs(%Sub{output: out, a: a, b: b}) do
    [out.name | value_refs(a) ++ value_refs(b)]
  end
  defp get_signal_refs(%Mux{output: out, cases: cases, default: default}) do
    case_refs = Enum.flat_map(cases, fn {cond, val} ->
      value_refs(cond) ++ value_refs(val)
    end)
    [out.name | case_refs ++ value_refs(default)]
  end
  defp get_signal_refs(%Cast{output: out, input: inp}) do
    [out.name | value_refs(inp)]
  end
  defp get_signal_refs(%Assign{output: out, input: inp}) do
    [out.name | value_refs(inp)]
  end
  defp get_signal_refs(%BitAnd{output: out, a: a, b: b}) do
    [out.name | value_refs(a) ++ value_refs(b)]
  end
  defp get_signal_refs(%BitOr{output: out, a: a, b: b}) do
    [out.name | value_refs(a) ++ value_refs(b)]
  end
  defp get_signal_refs(%Eq{output: out, a: a, b: b}) do
    [out.name | value_refs(a) ++ value_refs(b)]
  end
  defp get_signal_refs(_), do: []

  defp value_refs(%Signal{name: name}), do: [name]
  defp value_refs(%Const{}),            do: []
  defp value_refs(op) when is_struct(op), do: get_signal_refs(op)
  defp value_refs(_),                   do: []

  # ── Clock Reference Checks ─────────────────────────────────────────────────

  defp check_clock_references(errors, %Design{clocks: clocks, ops: ops}) do
    known_clocks = MapSet.new(clocks, & &1.name)

    Enum.reduce(ops, errors, fn
      %Reg{clock: clock} = op, acc ->
        if MapSet.member?(known_clocks, clock.name) do
          acc
        else
          [%Error{message: "Unknown clock referenced", op: op, details: clock.name} | acc]
        end
      _, acc -> acc
    end)
  end

  # ── Signedness Checks ──────────────────────────────────────────────────────

  defp check_signedness(errors, %Design{ops: ops}) do
    Enum.reduce(ops, errors, fn op, acc ->
      case check_op_signedness(op) do
        :ok           -> acc
        {:error, msg} -> [%Error{message: msg, op: op} | acc]
      end
    end)
  end

  defp check_op_signedness(%Add{a: a, b: b}), do: check_binary_signedness(a, b)
  defp check_op_signedness(%Sub{a: a, b: b}), do: check_binary_signedness(a, b)
  defp check_op_signedness(_),                do: :ok

  defp check_binary_signedness(a, b) do
    sa = get_signedness(a)
    sb = get_signedness(b)
    cond do
      sa == nil or sb == nil -> :ok
      sa == sb               -> :ok
      true -> {:error, "Signedness mismatch: #{sa} vs #{sb}"}
    end
  end

  defp get_signedness(%Signal{signed: s}), do: s
  defp get_signedness(%Const{signed: s}),  do: s
  defp get_signedness(_),                  do: nil

  # ── Width Checks ───────────────────────────────────────────────────────────

  defp check_widths(errors, %Design{ops: ops}) do
    Enum.reduce(ops, errors, fn op, acc ->
      case check_op_widths(op) do
        :ok           -> acc
        {:error, msg} -> [%Error{message: msg, op: op} | acc]
      end
    end)
  end

  defp check_op_widths(%Add{output: out, a: a, b: b}),
    do: check_arithmetic_widths(out, a, b)
  defp check_op_widths(%Sub{output: out, a: a, b: b}),
    do: check_arithmetic_widths(out, a, b)

  defp check_op_widths(%Mux{output: out, cases: cases, default: default}) do
    out_width  = out.width
    all_values = [default | Enum.map(cases, &elem(&1, 1))]

    mismatched = Enum.find(all_values, fn val ->
      w = get_width(val)
      w != nil and w != out_width
    end)

    if mismatched do
      {:error, "Mux value width #{get_width(mismatched)} doesn't match output width #{out_width}"}
    else
      :ok
    end
  end

  defp check_op_widths(%Eq{a: a, b: b}) do
    wa = get_width(a)
    wb = get_width(b)
    # For equality comparisons, warn if a constant value cannot fit in the
    # signal width — the comparison will never be true, which is almost
    # always a bug (e.g. comparing a 22-bit counter to a value > 4_194_303).
    cond do
      wa == nil or wb == nil -> :ok
      wa == wb               -> :ok
      true ->
        # Check if a constant exceeds the signal's range
        {sig_width, const_val} = case {a, b} do
          {%Signal{width: w}, %Const{value: v}} -> {w, v}
          {%Const{value: v}, %Signal{width: w}} -> {w, v}
          _ -> {nil, nil}
        end
        if sig_width != nil and const_val != nil and is_integer(const_val) do
          max_val = :math.pow(2, sig_width) |> trunc() |> Kernel.-(1)
          if const_val > max_val do
            {:error, "Comparison value #{const_val} cannot fit in #{sig_width}-bit signal (max #{max_val}) — comparison will never be true"}
          else
            :ok
          end
        else
          :ok
        end
    end
  end

  defp check_op_widths(_), do: :ok

  defp check_arithmetic_widths(_out, a, b) do
    wa = get_width(a)
    wb = get_width(b)
    cond do
      wa == nil or wb == nil -> :ok
      wa == wb               -> :ok
      true -> {:error, "Width mismatch in arithmetic: #{wa} vs #{wb}"}
    end
  end

  defp get_width(%Signal{width: w}), do: w
  defp get_width(%Const{width: w}),  do: w
  defp get_width(_),                 do: nil

  # ── Single Driver Check ────────────────────────────────────────────────────

  defp check_single_driver(errors, %Design{ops: ops}) do
    drivers =
      ops
      |> Enum.map(&get_output/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.group_by(& &1.name)

    Enum.reduce(drivers, errors, fn
      {_name, [_single]}, acc -> acc
      {name, multiple},   acc ->
        [%Error{
          message: "Multiple drivers for signal",
          details: %{signal: name, count: length(multiple)}
        } | acc]
    end)
  end

  defp get_output(%Reg{output: out}),    do: out
  defp get_output(%Add{output: out}),    do: out
  defp get_output(%Sub{output: out}),    do: out
  defp get_output(%Mux{output: out}),    do: out
  defp get_output(%Cast{output: out}),   do: out
  defp get_output(%Assign{output: out}), do: out
  defp get_output(%BitAnd{output: out}), do: out
  defp get_output(%BitOr{output: out}),  do: out
  defp get_output(%Eq{output: out}),     do: out
  defp get_output(_),                    do: nil

  # ── Register Clock Check ───────────────────────────────────────────────────

  defp check_registers_have_clocks(errors, %Design{ops: ops}) do
    Enum.reduce(ops, errors, fn
      %Reg{clock: nil} = op, acc ->
        [%Error{message: "Register without clock", op: op} | acc]
      _, acc -> acc
    end)
  end

  # ── CDC Crossing Checks ────────────────────────────────────────────────────
  #
  # A signal driven by a Reg in domain A must not be read by a Reg in domain B
  # without an explicit CDC primitive. CDC-safe signals are whitelisted via
  # design.cdc_safe_signals (a MapSet populated by Hw.CDC.* instances).

  defp check_cdc_crossings(errors, %Design{ops: ops} = design) do
    reg_clock_map = Enum.reduce(ops, %{}, fn
      %Reg{output: out, clock: clk}, m -> Map.put(m, out.name, clk)
      _, m -> m
    end)

    cdc_safe = Map.get(design, :cdc_safe_signals, MapSet.new())

    Enum.reduce(ops, errors, fn
      %Reg{output: out, input: inp, clock: dst_clk} = op, acc ->
        Enum.reduce(collect_signal_names(inp), acc, fn sig_name, inner ->
          case Map.get(reg_clock_map, sig_name) do
            nil -> inner

            %Clock{name: src_name} = src_clk ->
              cond do
                src_clk.name == dst_clk.name     -> inner
                MapSet.member?(cdc_safe, sig_name) -> inner
                true ->
                  [%Error{
                    message: "Unsafe clock domain crossing",
                    op: op,
                    details: %{
                      signal:     sig_name,
                      src_domain: src_name,
                      dst_domain: dst_clk.name,
                      dst_reg:    out.name
                    }
                  } | inner]
              end
          end
        end)

      _, acc -> acc
    end)
  end

  defp collect_signal_names(%Signal{name: name}), do: [name]
  defp collect_signal_names(%Const{}),            do: []
  defp collect_signal_names(_),                   do: []

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp signal_name(%Signal{name: name}), do: name
  defp signal_name(_),                   do: nil
end
