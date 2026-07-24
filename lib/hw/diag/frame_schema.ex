defmodule Hw.Diag.FrameSchema do
  @moduledoc """
  One source of truth for a US1 telemetry frame's field layout.

  ## Why this exists

  The original `Hw.Diag.HealthReport` hand-built its ASCII line as a flat
  `char_at` template: a bare `hdl_case <<idx::8>>` mapping each byte index to a
  literal character or a substituted value. Two independent failure modes lived
  in that shape, both of which produced *legal-but-wrong* output with no error:

    1. **Duplicate index** — two arms under the same `idx`. The later silently
       shadows the earlier (case arms are last-wins), so a byte slot renders the
       wrong field. This is now caught structurally in the elaborator
       (`Sequential.check_duplicate_literal_arms!`).

    2. **Duplicate label** — two *different* signals emitted under the same
       textual label (`RX`, `TX`, `EP` each appeared twice on the health line).
       The frame is still valid Verilog and streams fine, but any consumer that
       keys on the label loses information: the second token overwrites the
       first. That is invisible at the HDL layer because a "label" is just ASCII
       bytes there — nothing to collide.

  This module closes hole #2 at the point where labels actually exist: the frame
  definition. A frame is declared as an ordered list of fields, each with a
  unique `key`. `build/1` raises at compile/load time on a duplicate key, so a
  copy-pasted or mistyped column is a hard error instead of silent data loss.
  The same schema then drives BOTH the wire layout and the host-side parser, so
  the producer and consumer can never drift.

  ## Field

  A field is `%{key, label, width, base, kind}`:

    * `:key`   — unique atom identifying the field to consumers (e.g. `:rx_state`
                 vs `:lat_rx_active`, even though both historically print "RX").
    * `:label` — the human token prefix on the wire (may repeat across fields;
                 only `:key` must be unique). E.g. `"RX"`.
    * `:width` — number of value characters on the wire (1 for a digit, 2/4 for
                 hex bytes/words).
    * `:base`  — `10` or `16`; how the value characters encode the number.
    * `:kind`  — `:sticky` (a latch: did this ever happen) or `:live` (current
                 state), for documentation/rendering only.

  ## Usage

      schema =
        Hw.Diag.FrameSchema.build([
          {:pll_locked,   "PLL",  1, 10, :live},
          {:rst,          "RST",  1, 10, :live},
          {:lat_rx_active,"RX",   1, 10, :sticky},   # sticky "RX"
          {:rx_state,     "RX",   1, 10, :live},     # live "RX" — same label, DISTINCT key: OK
          {:dev_addr,     "A",    2, 16, :live},
          {:req,          "Q",    4, 16, :live}
        ])

      Hw.Diag.FrameSchema.keys(schema)     # [:pll_locked, :rst, ...]  (order preserved)
      Hw.Diag.FrameSchema.parse(schema, line)  # %{key => integer}

  Two fields with the same `:key` raise `ArgumentError` from `build/1`.
  """

  @enforce_keys [:fields]
  defstruct fields: []

  @type base :: 10 | 16
  @type kind :: :sticky | :live
  @type field :: %{
          key: atom(),
          label: String.t(),
          width: pos_integer(),
          base: base(),
          kind: kind()
        }
  @type t :: %__MODULE__{fields: [field()]}

  @doc """
  Build a validated schema from an ordered list of field tuples
  `{key, label, width, base, kind}`. Raises `ArgumentError` if any `:key`
  repeats — the whole point of the schema is that keys are unique.
  """
  @spec build([tuple()]) :: t()
  def build(field_tuples) when is_list(field_tuples) do
    fields =
      Enum.map(field_tuples, fn
        {key, label, width, base, kind}
        when is_atom(key) and is_binary(label) and is_integer(width) and width > 0 and
               base in [10, 16] and kind in [:sticky, :live] ->
          %{key: key, label: label, width: width, base: base, kind: kind}

        other ->
          raise ArgumentError,
                "invalid telemetry field #{inspect(other)} — expected " <>
                  "{key :: atom, label :: string, width :: pos_int, base :: 10|16, " <>
                  "kind :: :sticky|:live}"
      end)

    assert_unique_keys!(fields)

    %__MODULE__{fields: fields}
  end

  defp assert_unique_keys!(fields) do
    dups =
      fields
      |> Enum.frequencies_by(& &1.key)
      |> Enum.filter(fn {_k, n} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))

    if dups != [] do
      raise ArgumentError,
            "telemetry frame has duplicate field key(s): #{inspect(dups)}. " <>
              "Each field needs a UNIQUE key even if two fields share a display " <>
              "label (that is exactly the RX/TX/EP collision this schema prevents). " <>
              "Rename the colliding key(s)."
    end

    :ok
  end

  @doc "Ordered list of field keys."
  @spec keys(t()) :: [atom()]
  def keys(%__MODULE__{fields: fields}), do: Enum.map(fields, & &1.key)

  @doc "The field list (ordered)."
  @spec fields(t()) :: [field()]
  def fields(%__MODULE__{fields: fields}), do: fields

  @doc """
  Parse a telemetry line into `%{key => integer}`.

  Parsing is **width-authoritative and positional**: separators (`|`) and all
  whitespace are stripped to a single continuous character stream, then each
  schema field in order consumes `label` + an optional `=` + exactly `width`
  value characters (in the field's base) from the front of the stream. Because
  the schema is ordered, label repeats disambiguate by position — `RX` (sticky)
  and `RX` (live) bind to their two distinct keys even though the wire label is
  identical.

  Driving the parse off each field's known width (rather than off whitespace
  tokens) makes it immune to spacing bugs in the HDL template: a frame that
  emits `... D0 N0HSK1 ...` with a missing space still parses correctly, because
  the parser takes exactly one char after `N` and then looks for `HSK` next.
  Returns `{:ok, map}` or `:error` if the stream doesn't match the schema
  (a truncated/garbled line).
  """
  @spec parse(t(), String.t()) :: {:ok, %{atom() => integer()}} | :error
  def parse(%__MODULE__{fields: fields}, line) when is_binary(line) do
    # Collapse to one separator-free stream. `|` and whitespace are layout only.
    stream =
      line
      |> String.replace("|", "")
      |> String.replace(~r/\s+/, "")

    do_parse(fields, stream, %{})
  end

  defp do_parse([], _stream, acc), do: {:ok, acc}

  defp do_parse([field | rest_fields], stream, acc) do
    case take_field(field, stream) do
      {:ok, value, rest_stream} ->
        do_parse(rest_fields, rest_stream, Map.put(acc, field.key, value))

      :error ->
        :error
    end
  end

  # Consume one field from the FRONT of the stream: its label, an optional `=`,
  # then exactly `width` value characters parsed in `base`. Returns the value
  # and the remaining stream, or :error if the front doesn't match this field.
  defp take_field(%{label: label, width: width, base: base}, stream) do
    with {^label, after_label} <- String.split_at(stream, String.length(label)),
         after_eq <- strip_eq(after_label),
         {value_chars, rest} <- String.split_at(after_eq, width),
         true <- String.length(value_chars) == width,
         {v, ""} <- Integer.parse(value_chars, base) do
      {:ok, v, rest}
    else
      _ -> :error
    end
  end

  defp strip_eq("=" <> rest), do: rest
  defp strip_eq(other), do: other
end
