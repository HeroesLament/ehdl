defmodule Hw.Census do
  @moduledoc """
  Post-synthesis census of a yosys JSON netlist.

  Reads the netlist that `synth_xilinx` writes (`write_json`) and measures the
  things that decide whether nextpnr can route it, before any place and route
  is run:

    * LUT-input fanout per net. Counts LUT and MUXF input pins only. This is
      the binding limit for router2 on xc7: a few nets driving hundreds of LUT
      inputs set the router iteration time, LUT count does not.
    * Control-pin fanout per net (FF CE / R / S / CLR / PRE). Cheap: one pin
      per slice per control set.
    * Control sets: distinct `{clock, enable, set/reset}` triples over all
      flip-flops, and how many FFs sit in small ones.
    * Cell counts by type and the resource summary.

  The census works on the flat top module. Net names are the shortest public
  (non-`$`) name yosys kept for a bit; `src` is that name's source location
  in the emitted Verilog, which `Hw.Census.Attribution` uses to map EHDL
  temporaries back to the expression that made them.

      {:ok, c} = Hw.Census.load("build/top.json")
      Hw.Census.histogram(c)
      Hw.Census.top_nets(c, 20)
  """

  defstruct module: nil,
            cells: %{},
            names: %{},
            src: %{},
            drivers: %{},
            cell_inputs: %{},
            lut_fanout: %{},
            ctl_fanout: %{},
            control_sets: %{}

  @type bit_id :: non_neg_integer()
  @type t :: %__MODULE__{}

  @lut_prefixes ["LUT", "MUXF"]
  @ctl_ports ["CE", "R", "S", "CLR", "PRE"]
  @sr_ports ["R", "S", "CLR", "PRE"]

  # ── Loading ─────────────────────────────────────────────────────────

  @doc """
  Load a yosys JSON netlist and build the census.

  Options:
    * `:module` - module name to read (default: the module marked `top`,
      else the only module, else `"top"`).
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts \\ []) do
    with {:ok, text} <- File.read(path),
         {:ok, json} <- JSON.decode(text) do
      from_json(json, opts)
    end
  end

  @doc "Build the census from an already decoded yosys JSON map."
  @spec from_json(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"modules" => modules}, opts) do
    case pick_module(modules, Keyword.get(opts, :module)) do
      {:ok, name, mod} -> {:ok, build(name, mod)}
      error -> error
    end
  end

  def from_json(_json, _opts), do: {:error, :not_a_yosys_netlist}

  defp pick_module(modules, nil) do
    tops =
      for {name, mod} <- modules,
          Map.get(mod["attributes"] || %{}, "top") not in [nil, 0, "0"],
          do: {name, mod}

    case {tops, Map.to_list(modules)} do
      {[{name, mod}], _} -> {:ok, name, mod}
      {_, [{name, mod}]} -> {:ok, name, mod}
      _ -> pick_module(modules, "top")
    end
  end

  defp pick_module(modules, name) do
    case Map.fetch(modules, name) do
      {:ok, mod} -> {:ok, name, mod}
      :error -> {:error, {:no_module, name, Map.keys(modules)}}
    end
  end

  defp build(name, mod) do
    {names, src} = net_names(mod["netnames"] || %{})

    acc = %__MODULE__{module: name, names: names, src: src}

    (mod["cells"] || %{})
    |> Enum.reduce(acc, fn {cell_name, cell}, acc -> add_cell(acc, cell_name, cell) end)
  end

  # Best public name per bit. yosys keeps every alias of a net; prefer a
  # design name over an emitter temporary (`_eq_123`), then the shortest.
  # Bits of a multi-bit wire are named `wire[i]`.
  defp net_names(netnames) do
    Enum.reduce(netnames, {%{}, %{}}, fn {name, info}, {names, src} ->
      if String.starts_with?(name, "$") do
        {names, src}
      else
        file_src = get_in(info, ["attributes", "src"])
        bits = info["bits"] || []
        wide? = length(bits) > 1

        bits
        |> Enum.with_index()
        |> Enum.reduce({names, src}, fn
          {bit, i}, {n, s} when is_integer(bit) ->
            label = if wide?, do: "#{name}[#{i}]", else: name

            case Map.fetch(n, bit) do
              {:ok, old} ->
                if name_rank(label) < name_rank(old),
                  do: {Map.put(n, bit, label), put_src(s, bit, file_src)},
                  else: {n, s}

              :error ->
                {Map.put(n, bit, label), put_src(s, bit, file_src)}
            end

          _const, acc ->
            acc
        end)
      end
    end)
  end

  defp name_rank(label), do: {String.starts_with?(label, "_"), byte_size(label), label}

  @doc "Wire name of a census net label (`foo[3]` -> `foo`)."
  @spec base_name(String.t()) :: String.t()
  def base_name(label), do: String.replace(label, ~r/\[\d+\]$/, "")

  defp put_src(s, _bit, nil), do: s
  defp put_src(s, bit, file_src), do: Map.put(s, bit, file_src)

  defp add_cell(acc, cell_name, cell) do
    type = cell["type"]
    conns = cell["connections"] || %{}
    dirs = cell["port_directions"] || %{}
    lut? = String.starts_with?(type, @lut_prefixes)
    ff? = flip_flop?(type)

    # Data inputs only (no clock / control pins), for attribution walks.
    inputs =
      for {port, bits} <- conns,
          Map.get(dirs, port) == "input",
          not (ff? and port in ["C" | @ctl_ports]),
          not String.contains?(port, "CLK"),
          b <- int_bits(bits),
          do: b

    acc = %{acc | cells: Map.update(acc.cells, type, 1, &(&1 + 1))}
    acc = %{acc | cell_inputs: Map.put(acc.cell_inputs, cell_name, Enum.uniq(inputs))}
    acc = if ff?, do: add_control_set(acc, conns), else: acc

    Enum.reduce(conns, acc, fn {port, bits}, acc ->
      case Map.get(dirs, port) do
        "output" ->
          driver = {cell_name, type}
          Enum.reduce(int_bits(bits), acc, &%{&2 | drivers: Map.put(&2.drivers, &1, driver)})

        "input" when lut? ->
          Enum.reduce(int_bits(bits), acc, &%{&2 | lut_fanout: bump(&2.lut_fanout, &1)})

        "input" when ff? and port in @ctl_ports ->
          Enum.reduce(int_bits(bits), acc, &%{&2 | ctl_fanout: bump(&2.ctl_fanout, &1)})

        _ ->
          acc
      end
    end)
  end

  defp add_control_set(acc, conns) do
    clk = first_bit(conns["C"], "?")
    ce = first_bit(conns["CE"], "1")
    sr = @sr_ports |> Enum.find_value("0", &(conns[&1] && first_bit(conns[&1], nil)))
    key = {clk, ce, sr}
    %{acc | control_sets: bump(acc.control_sets, key)}
  end

  defp flip_flop?(type), do: String.starts_with?(type, "FD")

  defp first_bit([b | _], _default), do: b
  defp first_bit(_, default), do: default

  defp int_bits(bits), do: Enum.filter(bits, &is_integer/1)

  defp bump(map, key), do: Map.update(map, key, 1, &(&1 + 1))

  # ── Queries ─────────────────────────────────────────────────────────

  @default_edges [16, 64, 256, 1024]

  @doc """
  LUT-input fanout histogram: `[{upper_edge, count}]`, where each net is
  counted in the first bucket whose edge is >= its fanout. The last bucket
  is `:inf`.
  """
  @spec histogram(t(), [pos_integer()]) :: [{pos_integer() | :inf, non_neg_integer()}]
  def histogram(%__MODULE__{lut_fanout: lf}, edges \\ @default_edges) do
    edges = Enum.sort(edges) ++ [:inf]
    counts = Map.new(edges, &{&1, 0})

    lf
    |> Map.values()
    |> Enum.reduce(counts, fn k, acc ->
      edge = Enum.find(edges, &(&1 == :inf or k <= &1))
      Map.update!(acc, edge, &(&1 + 1))
    end)
    |> Enum.sort_by(fn {e, _} -> if e == :inf, do: :infinity, else: e end)
  end

  @doc "Largest LUT-input fanout of any net (0 for an empty netlist)."
  @spec max_lut_fanout(t()) :: non_neg_integer()
  def max_lut_fanout(%__MODULE__{lut_fanout: lf}) do
    lf |> Map.values() |> Enum.max(fn -> 0 end)
  end

  @doc "Number of nets with LUT-input fanout strictly above `limit`."
  @spec nets_above(t(), non_neg_integer()) :: non_neg_integer()
  def nets_above(%__MODULE__{lut_fanout: lf}, limit) do
    Enum.count(lf, fn {_bit, k} -> k > limit end)
  end

  @doc """
  The `n` nets with the highest LUT-input fanout, highest first.

  Each entry: `%{bit, lut, ctl, driver, driver_type, name, src}`. `name` is
  nil for nets yosys kept no public name for (typically ABC LUT outputs).
  """
  @spec top_nets(t(), pos_integer()) :: [map()]
  def top_nets(%__MODULE__{} = c, n) do
    c.lut_fanout
    |> Enum.sort_by(fn {bit, k} -> {-k, bit} end)
    |> Enum.take(n)
    |> Enum.map(fn {bit, k} -> net_info(c, bit, k) end)
  end

  @doc "Nets with LUT-input fanout above `limit`, highest first."
  @spec nets_over(t(), non_neg_integer()) :: [map()]
  def nets_over(%__MODULE__{} = c, limit) do
    c.lut_fanout
    |> Enum.filter(fn {_bit, k} -> k > limit end)
    |> Enum.sort_by(fn {bit, k} -> {-k, bit} end)
    |> Enum.map(fn {bit, k} -> net_info(c, bit, k) end)
  end

  @doc "Census view of one net bit."
  @spec net_info(t(), bit_id(), non_neg_integer() | nil) :: map()
  def net_info(%__MODULE__{} = c, bit, lut \\ nil) do
    {driver, type} = Map.get(c.drivers, bit, {nil, nil})

    %{
      bit: bit,
      lut: lut || Map.get(c.lut_fanout, bit, 0),
      ctl: Map.get(c.ctl_fanout, bit, 0),
      driver: driver,
      driver_type: type,
      name: Map.get(c.names, bit),
      src: Map.get(c.src, bit)
    }
  end

  @doc """
  Control-set summary: total sets, and the sets / FFs below `small` FFs per
  set (default 8, one slice's worth on xc7).
  """
  @spec control_set_summary(t(), pos_integer()) :: map()
  def control_set_summary(%__MODULE__{control_sets: cs}, small \\ 8) do
    small_sets = Enum.filter(cs, fn {_k, n} -> n < small end)

    %{
      sets: map_size(cs),
      small_sets: length(small_sets),
      ffs_in_small_sets: small_sets |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      small: small
    }
  end

  @doc """
  Resource summary from cell counts.

  `lut` counts LUT1..LUT6 cells (yosys view; nextpnr's LUTX is larger
  because it counts LUT5/LUT6 halves and route-throughs).
  """
  @spec resources(t()) :: map()
  def resources(%__MODULE__{cells: cells}) do
    sum = fn pred -> cells |> Enum.filter(fn {t, _} -> pred.(t) end) |> Enum.map(&elem(&1, 1)) |> Enum.sum() end

    %{
      lut: sum.(&String.match?(&1, ~r/^LUT[1-6]$/)),
      ff: sum.(&flip_flop?/1),
      carry4: Map.get(cells, "CARRY4", 0),
      muxf: sum.(&String.starts_with?(&1, "MUXF")),
      srl: sum.(&String.starts_with?(&1, "SRL")),
      lutram: sum.(&String.starts_with?(&1, "RAM")),
      dsp: Map.get(cells, "DSP48E1", 0),
      ramb18: Map.get(cells, "RAMB18E1", 0),
      ramb36: Map.get(cells, "RAMB36E1", 0)
    }
  end

  @doc "Cell types driving the nets above `limit`, as `%{type => count}`."
  @spec driver_types_over(t(), non_neg_integer()) :: %{String.t() => non_neg_integer()}
  def driver_types_over(%__MODULE__{} = c, limit) do
    c.lut_fanout
    |> Enum.filter(fn {_bit, k} -> k > limit end)
    |> Enum.map(fn {bit, _k} -> c.drivers |> Map.get(bit, {nil, "?"}) |> elem(1) end)
    |> Enum.frequencies()
  end
end
