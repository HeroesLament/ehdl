defmodule Hw.Analysis.Rules.EndianMismatch do
  @moduledoc """
  Detects direct connections between signals with mismatched endianness.

  Multi-byte signals carry a byte order annotation. Connecting a big-endian
  signal directly to a little-endian signal without an explicit byte swap
  produces silently corrupted data — the signal widths match, timing is
  correct, but byte fields are reversed.

  ## What this catches

      wire :usb_wLength, 16, endian: :little   # USB descriptor — LE
      wire :eth_length,  16, endian: :big       # Ethernet — BE

      comb do
        eth_length = usb_wLength   # silent bug — bytes reversed
      end

  ## What is allowed

  An explicit byte-swap via bit-slice reassignment acknowledges the crossing:

      comb do
        eth_length = {usb_wLength[0..7], usb_wLength[8..15]}
      end

  Single-byte (width ≤ 8) signals are exempt — endianness is meaningless
  for a single byte.

  ## Priority
  """

  @behaviour Hw.Analysis.Rule

  @dialyzer {:nowarn_function, check_op: 2}

  alias Hw.Analysis.Diagnostic
  alias Hw.IR.Ops

  @impl true
  def priority, do: 27

  # Inspects the elaborated netlist (.signals/.ops), not module metadata.
  @impl true
  def stage, do: :ir

  @impl true
  def run(design) do
    signal_map = Map.new(design.signals, &{&1.name, &1})

    design.ops
    |> Enum.flat_map(&check_op(&1, signal_map))
  end

  # The guard matters: an Assign's operand can be a %Const{}, which has no
  # :name. Dereferencing it raised KeyError and, before rules were isolated,
  # took the whole analysis suite down.
  defp check_op(%Ops.Assign{output: out_sig, input: in_sig}, signal_map)
       when is_map_key(out_sig, :name) and is_map_key(in_sig, :name) do
    out = Map.get(signal_map, out_sig.name, out_sig)
    inp = Map.get(signal_map, in_sig.name, in_sig)

    out_endian = Map.get(out, :endian)
    inp_endian = Map.get(inp, :endian)
    out_width  = Map.get(out, :width, 1)
    inp_width  = Map.get(inp, :width, 1)

    # Only flag when both have explicit endian annotations, they differ,
    # and both signals are wider than 8 bits
    if out_endian != nil and inp_endian != nil and
       out_endian != inp_endian and
       is_integer(out_width) and out_width > 8 and
       is_integer(inp_width) and inp_width > 8 do
      [Diagnostic.warning(
        :endian_mismatch,
        "Signal `#{inp.name}` (#{inp_endian}-endian) assigned directly to " <>
        "`#{out.name}` (#{out_endian}-endian) — byte order mismatch, use explicit byte swap if intentional",
        Map.get(inp, :source_location),
        context: %{signal: inp.name, target: out.name,
                   input_endian: inp_endian, output_endian: out_endian}
      )]
    else
      []
    end
  end

  defp check_op(_, _), do: []
end
