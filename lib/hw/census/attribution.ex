defmodule Hw.Census.Attribution do
  @moduledoc """
  Map census nets back to the RTL that made them.

  The flat Verilog emitter names intermediate expressions with generated
  temporaries (`_eq_154027`, `_bpslice_100159`, `_cat_12393`, ...). After
  synthesis many high-fanout nets carry only such a name, or no public name
  at all (ABC LUT outputs). This module reads the emitted Verilog once,
  keeps the right-hand side of every temporary's `assign`, and explains a
  net as:

    * `expr`    - the temporary's expression, e.g.
                  `phy_trx_rx_u_ldpc_ldsel == 32'd1`
    * `signals` - the named (non-temporary) signals it is built from,
                  following temporaries and, for unnamed nets, the driving
                  cells' inputs a few levels back
    * `block`   - the longest common `_`-separated prefix of those signals,
                  which for the flat emitter is the instance path
                  (`phy_trx_rx_u_ldpc`)

  This is attribution by name, not by elaboration: it needs only the
  netlist and the Verilog it was synthesised from.
  """

  alias Hw.Census

  defstruct exprs: %{}

  @type t :: %__MODULE__{exprs: %{String.t() => String.t()}}

  @assign ~r/^\s*assign\s+\\?([A-Za-z_][A-Za-z0-9_$]*)\s*=\s*(.*?);\s*$/
  @ident ~r/(?<!['\w$\\])[A-Za-z_][A-Za-z0-9_$]*/
  @keywords ~w(assign wire reg signed unsigned)
  @max_depth 4
  # Inputs followed per cell when walking back from an unnamed net; keeps a
  # walk through a DSP or BRAM (dozens of inputs) bounded.
  @max_walk 16

  @doc """
  Read temporaries' assignments from an emitted Verilog file.

  Only names that look like emitter temporaries (leading `_`) are kept.
  """
  @spec load_verilog(Path.t()) :: {:ok, t()} | {:error, term()}
  def load_verilog(path) do
    if File.regular?(path) do
      exprs =
        path
        |> File.stream!()
        |> Enum.reduce(%{}, fn line, acc ->
          if String.contains?(line, "assign _") do
            case Regex.run(@assign, line) do
              [_, name, rhs] -> if temp?(name), do: Map.put(acc, name, rhs), else: acc
              _ -> acc
            end
          else
            acc
          end
        end)

      {:ok, %__MODULE__{exprs: exprs}}
    else
      {:error, {:no_verilog, path}}
    end
  end

  @doc "Build from a map of temporary name to expression (tests, tooling)."
  @spec from_exprs(%{String.t() => String.t()}) :: t()
  def from_exprs(exprs), do: %__MODULE__{exprs: exprs}

  @doc """
  The Verilog file the netlist was synthesised from, taken from the `src`
  attributes yosys kept on net names. Returns the most common `.v` path.
  """
  @spec verilog_path(Census.t()) :: String.t() | nil
  def verilog_path(%Census{src: src}) do
    src
    |> Map.values()
    |> Enum.map(&(&1 |> String.split("|") |> hd() |> String.split(":") |> hd()))
    |> Enum.filter(&String.ends_with?(&1, ".v"))
    |> Enum.frequencies()
    |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0} end)
    |> elem(0)
  end

  @doc """
  Explain one census net (a map from `Census.top_nets/2` or
  `Census.net_info/3`). Returns the net map with `:label`, `:expr`,
  `:signals` and `:block` added.
  """
  @spec explain(Census.t(), t(), map()) :: map()
  def explain(%Census{} = c, %__MODULE__{} = a, net) do
    {expr, signals} =
      case net.name do
        nil ->
          {nil, signals_of_bit(c, a, net.bit, @max_depth)}

        label ->
          name = Census.base_name(label)

          if temp?(name) do
            expr = Map.get(a.exprs, name)
            sigs = if expr, do: expand(a, idents(expr), @max_depth), else: []
            sigs = if sigs == [], do: signals_of_bit(c, a, net.bit, @max_depth), else: sigs
            {expr, sigs}
          else
            {nil, [name]}
          end
      end

    signals = signals |> Enum.uniq() |> Enum.sort()

    Map.merge(net, %{
      label: net.name || "<#{net.driver_type || "?"} bit #{net.bit}>",
      expr: expr,
      signals: signals,
      block: block_of(signals)
    })
  end

  @doc """
  Longest common `_`-separated prefix of the signal names. When the names
  share fewer than two tokens: the three-token prefix most of them share,
  if one is shared by more than half, else the common prefix with `_*`
  (`phy_*`), else nil. A single name drops its last token.
  """
  @spec block_of([String.t()]) :: String.t() | nil
  def block_of([]), do: nil
  def block_of([one]), do: one |> String.split("_") |> Enum.drop(-1) |> Enum.join("_") |> nil_if_empty()

  def block_of(names) do
    tokens = Enum.map(names, &String.split(&1, "_"))
    common = common_prefix(tokens)

    {best, count} =
      tokens
      |> Enum.map(&(&1 |> Enum.take(3) |> Enum.join("_")))
      |> Enum.frequencies()
      |> Enum.max_by(fn {p, n} -> {n, p} end)

    cond do
      length(common) >= 2 -> Enum.join(common, "_")
      count * 2 > length(names) -> best
      common != [] -> Enum.join(common, "_") <> "_*"
      true -> nil
    end
  end

  # ── internals ──────────────────────────────────────────────────────

  @doc false
  def temp?(name), do: String.starts_with?(name, "_")

  defp idents(expr) do
    @ident
    |> Regex.scan(expr)
    |> List.flatten()
    |> Enum.reject(&(&1 in @keywords))
    |> Enum.uniq()
  end

  # Replace temporaries by the signals in their expressions, depth-limited.
  defp expand(_a, names, 0), do: Enum.reject(names, &temp?/1)

  defp expand(a, names, depth) do
    Enum.flat_map(names, fn name ->
      cond do
        not temp?(name) -> [name]
        expr = Map.get(a.exprs, name) -> expand(a, idents(expr), depth - 1)
        true -> []
      end
    end)
  end

  # Walk back through driving cells until named signals are found.
  defp signals_of_bit(_c, _a, _bit, 0), do: []

  defp signals_of_bit(c, a, bit, depth) do
    case Map.get(c.drivers, bit) do
      nil ->
        []

      {cell, _type} ->
        c.cell_inputs
        |> Map.get(cell, [])
        |> Enum.take(@max_walk)
        |> Enum.flat_map(fn in_bit ->
          case Map.get(c.names, in_bit) do
            nil ->
              signals_of_bit(c, a, in_bit, depth - 1)

            label ->
              name = Census.base_name(label)
              if temp?(name), do: expand(a, [name], depth - 1), else: [name]
          end
        end)
        |> Enum.uniq()
    end
  end

  defp common_prefix([first | rest]) do
    Enum.reduce(rest, first, fn toks, acc ->
      acc |> Enum.zip(toks) |> Enum.take_while(fn {x, y} -> x == y end) |> Enum.map(&elem(&1, 0))
    end)
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s
end
