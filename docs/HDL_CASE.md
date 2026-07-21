# `hdl_case` Theory of Operation

## What it is

`hdl_case` is EHDL's unified pattern matching primitive for hardware logic. It handles two distinct use cases under one syntax:

- **Plain pattern matching** — matching a signal against integer or atom constants, identical to Elixir's `case`
- **Binary pattern matching** — matching multiple packed signals against bitfield patterns, using `<<signal::width>>` syntax

Plain case:
```elixir
case tx_state do
  0 -> tx_state <= w3_1
  1 -> tx_shift <= tx_shift[7..1]
  5 -> tx_state <= w3_0
end
```

Binary case:
```elixir
hdl_case <<rx_state::1, sym_se0::1, sym_k::1>> do
  <<0::1, _::1, 0::1>> -> nil               # idle, no K — hold
  <<0::1, 0::1, 1::1>> -> rx_state <= one   # K detected — start SYNC
  <<1::1, 1::1, _::1>> -> rx_state <= zero  # SE0 — EOP
  <<1::1, 0::1, _::1>> -> prev_diff <= dp_diff  # active data
end
```

Plain patterns use bare `case`. Binary patterns require `hdl_case`. Both live under the same mental model: you're describing what output value each condition produces, and the elaborator builds a priority mux chain.

---

## The Elixir macro challenge

Binary pattern syntax creates a fundamental problem. In normal Elixir, `<<rx_state::1>>` inside a binary literal tries to evaluate `rx_state` as a variable at compile time. Inside an `on :clk do` block, there are no variables — only EHDL signal declarations. Elixir would reject this with a compile error.

The deeper problem: `on` and `comb` are macros that receive their `do:` block as an AST argument. But Elixir expands inner macros before passing the block to outer macros. So if `hdl_case` is a macro that returns `:ok` (the original approach), by the time `on` sees the block, the `hdl_case` call has already vanished — replaced by `:ok` — and the entire case statement is silently dropped.

This is why plain `case` worked historically but `hdl_case` did not: `case` is an Elixir special form, not a macro. Special forms survive in the AST unchanged. Macros expand and disappear.

---

## The process dictionary solution

`hdl_case` solves this by using the Erlang process dictionary as a compile-time side channel. All Elixir compilation happens in a single process, so the process dictionary is shared across all macro expansions in a module.

When `hdl_case` expands, it:

1. Generates a unique key atom: `:__hw_case_42__` (using a monotonic counter)
2. Stores the raw unevaluated AST `{subject_ast, clauses_ast}` in the process dict under that key
3. Expands to a syntactically valid Elixir expression: `case :__hw_case_42__ do _ -> nil end`

```elixir
defmacro hdl_case(subject, do: clauses) do
  key = :"__hw_case_#{:erlang.unique_integer([:positive, :monotonic])}__"
  Process.put(key, {subject, clauses})
  quote do
    case unquote(key) do
      _ -> nil
    end
  end
end
```

The `on` macro then receives a block containing `case :__hw_case_42__ do _ -> nil end`. This is a valid Elixir `case` expression — it compiles without error because the subject is just an atom and the single clause `_ -> nil` always matches. No signal names are evaluated.

When `parse_statement` encounters `{:case, _, [{:__hw_case_42__, _, nil}, ...]}`, it recognizes the atom key pattern, looks up the real AST from the process dictionary, and routes it through the binary case machinery:

```elixir
def parse_statement({:case, _, [expr, [do: clauses]]}) do
  {real_expr, real_clauses} = case expr do
    {key, _, nil} when is_atom(key) ->
      case Process.get(key) do
        {subj, cls} -> {subj, cls}   # hdl_case sentinel — use real AST
        nil         -> {expr, clauses}  # plain case — use as-is
      end
    _ -> {expr, clauses}
  end
  # ... rest of parse_statement
end
```

---

## How binary matching compiles to Verilog

Given this `hdl_case` from `fs_phy.ex`:

```elixir
hdl_case <<rx_state::1, sym_se0::1, sym_k::1>> do
  <<0::1, _::1, 0::1>> ->       # idle, no K — stay idle
    nil
  <<0::1, 0::1, 1::1>> ->       # K detected
    rx_state  <= one
    rx_ones   <= w3_0
  <<1::1, 1::1, _::1>> ->       # SE0 — EOP
    rx_state <= zero
    rx_ones  <= w3_0
  <<1::1, 0::1, _::1>> ->       # active data
    prev_diff <= dp_diff
end
```

The elaborator compiles this in five stages.

### Stage 1 — Pack the subject into a bus

The subject `<<rx_state::1, sym_se0::1, sym_k::1>>` becomes a concatenation of the three signals, ordered MSB-first:

```verilog
assign _cat_3314 = {phy_rx_state, phy_sym_se0, phy_sym_k};
//                  bit 2           bit 1          bit 0
```

### Stage 2 — Slice and compare each non-wildcard bit

For each clause arm, the elaborator generates one bit-slice and one equality check per non-wildcard position. Wildcards (`_`) are simply skipped — they contribute no logic.

**Arm `<<0::1, 0::1, 1::1>>` (K detected — three checks):**

```verilog
assign _bpslice_3410 = _cat_3314[2:2];          // rx_state bit
assign _bpeq_3426    = _bpslice_3410 == 1'd0;   // rx_state == 0?

assign _bpslice_3442 = _cat_3314[1:1];          // sym_se0 bit
assign _bpeq_3458    = _bpslice_3442 == 1'd0;   // sym_se0 == 0?

assign _bpslice_3490 = _cat_3314[0:0];          // sym_k bit
assign _bpeq_3506    = _bpslice_3490 == 1'd1;   // sym_k == 1?
```

**Arm `<<1::1, 1::1, _::1>>` (SE0 — two checks, wildcard skipped):**

```verilog
assign _bpslice_3538 = _cat_3314[2:2];          // rx_state bit
assign _bpeq_3554    = _bpslice_3538 == 1'd1;   // rx_state == 1?

assign _bpslice_3570 = _cat_3314[1:1];          // sym_se0 bit
assign _bpeq_3586    = _bpslice_3570 == 1'd1;   // sym_se0 == 1?

// No check for bit 0 — the _ wildcard generates nothing
```

### Stage 3 — AND all bit checks for each arm

```verilog
// Arm: K detected (bits 2,1,0 all checked)
assign _bpand_3474 = _bpeq_3426 & _bpeq_3458;   // rx==0 AND se0==0
assign _bpand_3522 = _bpand_3474 & _bpeq_3506;  // ... AND k==1

// Arm: SE0 (bits 2,1 checked, bit 0 wildcard)
assign _bpand_3602 = _bpeq_3554 & _bpeq_3586;   // rx==1 AND se0==1
```

### Stage 4 — Build a priority mux chain

The case result is a priority mux — each arm's match signal gates the corresponding result value, with later arms checked only if earlier arms didn't fire. The default (no match) holds the current register value.

For `rx_state` specifically:
- Arm 1 (`nil`) — no assignment to `rx_state`, contributes nothing
- Arm 2 (K detected) — `rx_state <= one` → result is `phy_one`
- Arm 3 (SE0) — `rx_state <= zero` → result is `phy_zero`
- Arm 4 (active data) — no assignment to `rx_state`, contributes nothing
- Default — hold current value `phy_rx_state`

```verilog
assign _case_3698 = _bpand_3522 ? phy_one        // K detected → 1
                  : _bpand_3602 ? phy_zero        // SE0 → 0
                  : phy_rx_state;                 // no match → hold
```

### Stage 5 — Gate on the enclosing `if` and register

The `hdl_case` is inside `if bnot(tx_act) and sample_en do`, which becomes an outer mux gating the entire case result:

```verilog
assign _bnot_3282 = ~phy_tx_act;
assign _land_3298 = _bnot_3282 & phy_sample_en;

assign _mux_3714  = _land_3298 ? _case_3698    // gate fires — use case result
                               : phy_rx_state;  // gate off — hold current value
```

Finally, the reset mux and register:

```verilog
assign _mux_4146 = rst ? phy_zero : _mux_3714;

// In the always block:
phy_rx_state <= _mux_4146;
```

---

## Plain case — how it differs

Plain `case tx_state do 0 -> ... 1 -> ... end` skips the entire concat/slice/bpand machinery. The subject is compared directly with `==`:

```verilog
assign _eq_N1 = sie_tx_state == 32'd0;
assign _eq_N2 = sie_tx_state == 32'd1;
assign _eq_N3 = sie_tx_state == 32'd5;

assign _case_N = _eq_N1 ? result_for_0
               : _eq_N2 ? result_for_1
               : _eq_N3 ? result_for_5
               : default_hold;
```

The structure is identical — a priority mux chain — just without the bit-packing layer.

---

## The `_bp` naming convention

Wires generated from binary pattern matching carry the `_bp` prefix to distinguish them from general-purpose wires:

| Prefix | Meaning |
|--------|---------|
| `_cat_N` | Concatenation of subject signals into a bus |
| `_bpslice_N` | Bit slice extracting one position from the bus |
| `_bpeq_N` | Equality check of a slice against a literal (0 or 1) |
| `_bpand_N` | AND of multiple bit checks for one clause arm |
| `_case_N` | Priority mux over all clause results |
| `_mux_N` | General-purpose mux (from `if/else`, outer gates, reset) |
| `_land_N` | Logical AND (from `and` in EHDL expressions) |
| `_bnot_N` | Logical NOT (from `bnot()`) |
| `_eq_N` | Equality (from `==` in plain expressions) |

---

## Why signal names work in binary subjects

The key property of `<<rx_state::1, sym_se0::1, sym_k::1>>` is that the signal names appear only in the **subject** position, never in the clause **patterns**. Clause patterns like `<<0::1, _::1, 1::1>>` contain only integer literals and wildcards — they are pure compile-time constants that Elixir can evaluate without any variable bindings.

The subject signals are stored as raw AST by the process dictionary mechanism and passed to `parse_case_subject`, which recognizes `{:<<>>, _, segments}` and calls `parse_binary_segment_subject` on each segment. This extracts `rx_state`, `sym_se0`, `sym_k` as signal references — atoms that the elaborator later looks up in the signal map to get their `Signal.t()` structs — and builds the `_cat_N` concatenation expression.

The Elixir compiler never sees these names as variables. The entire binary subject expression is captured as raw AST via the process dictionary before any evaluation occurs.