defmodule Mix.Tasks.Hw.Census do
  @moduledoc """
  Structural census of a synthesised netlist, checked against a device
  budget. Runs in seconds; run it before any place and route.

      mix hw.census build/top.json
      mix hw.census build/top.json --top 40 --target xc7z020
      mix hw.census build/top.json --verilog build/top.v

  Reads the yosys JSON (`write_json`) and reports:

    * resources (LUT, FF, CARRY4, MUXF, SRL, LUTRAM, DSP, BRAM)
    * LUT-input fanout: max, nets over 64 / 128 / 200 / 300, histogram,
      the cell types driving the big nets
    * control sets and how many FFs sit in small ones
    * the top nets by LUT-input fanout, attributed to the emitted Verilog
      expression and the instance prefix that made them
    * nets over the budget's warn threshold grouped by instance prefix
    * findings against the `Hw.Target` budget

  Attribution reads the Verilog named by the netlist's `src` attributes
  unless `--verilog` is given; `--no-attr` skips it.

  Exits with status 1 when the budget reports an error (a net over the hard
  LUT-input fanout gate, or a resource over 100%), so it can gate a build.

  ## Options

    * `--top N` - top nets to list (default 20)
    * `--target NAME` - budget from `Hw.Target` (default xc7z020)
    * `--module NAME` - netlist module (default: the top module)
    * `--verilog FILE` - Verilog the netlist was synthesised from
    * `--no-attr` - skip attribution
    * `--blocks N` - instance prefixes to list (default 15)
    * `--warnings-as-errors` - exit 1 on budget warnings too
  """

  use Mix.Task

  alias Hw.Census
  alias Hw.Census.Attribution

  @shortdoc "Structural census of a yosys netlist against a device budget"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile", [])

    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          top: :integer,
          target: :string,
          module: :string,
          verilog: :string,
          attr: :boolean,
          blocks: :integer,
          warnings_as_errors: :boolean
        ]
      )

    path =
      case rest do
        [p | _] -> p
        [] -> Mix.raise("usage: mix hw.census NETLIST.json [options]")
      end

    target_name = Keyword.get(opts, :target, "xc7z020")

    target =
      case Enum.find(Hw.Target.known(), &(Atom.to_string(&1) == target_name)) do
        nil -> Mix.raise("hw.census: unknown target #{target_name}; known: #{inspect(Hw.Target.known())}")
        name -> Hw.Target.get(name)
      end

    census =
      case Census.load(path, module: opts[:module]) do
        {:ok, c} -> c
        {:error, reason} -> Mix.raise("hw.census: cannot read #{path}: #{inspect(reason)}")
      end

    attr = if Keyword.get(opts, :attr, true), do: load_attr(census, opts[:verilog]), else: nil

    info = fn line -> Mix.shell().info(line) end
    info.("==> hw.census #{path} (module #{census.module}, target #{target.name})")
    print_summary(census, target, info)
    print_top(census, attr, Keyword.get(opts, :top, 20), info)
    print_blocks(census, attr, target.lut_input_fanout[:warn], Keyword.get(opts, :blocks, 15), info)

    findings = Hw.Target.check(census, target)
    print_findings(findings, target, info)

    fail? =
      Hw.Target.errors?(findings) or
        (Keyword.get(opts, :warnings_as_errors, false) and findings != [])

    if fail?, do: exit({:shutdown, 1})
  end

  # ── output ─────────────────────────────────────────────────────────

  defp load_attr(census, nil) do
    case Attribution.verilog_path(census) do
      nil -> nil
      path -> load_attr(census, path)
    end
  end

  defp load_attr(_census, path) do
    case Attribution.load_verilog(path) do
      {:ok, a} ->
        a

      {:error, reason} ->
        Mix.shell().info("note: no attribution (#{inspect(reason)})")
        nil
    end
  end

  defp print_summary(c, t, info) do
    r = Census.resources(c)
    cap = t.capacity
    pct = fn n, d -> :erlang.float_to_binary(n * 100 / d, decimals: 1) end

    info.(
      "resources  LUT #{r.lut} (#{pct.(r.lut, cap.lut)}%)  FF #{r.ff}  CARRY4 #{r.carry4}  MUXF #{r.muxf}" <>
        "  SRL #{r.srl}  LUTRAM #{r.lutram}  DSP #{r.dsp}/#{cap.dsp}  RAMB18 #{r.ramb18}  RAMB36 #{r.ramb36}"
    )

    over = fn k -> Census.nets_above(c, k) end

    info.(
      "fanout     max #{Census.max_lut_fanout(c)}  >64: #{over.(64)}  >128: #{over.(128)}" <>
        "  >200: #{over.(200)}  >300: #{over.(300)}"
    )

    hist =
      c
      |> Census.histogram()
      |> Enum.map_join("  ", fn
        {:inf, n} -> ">1024 #{n}"
        {e, n} -> "<=#{e} #{n}"
      end)

    info.("histogram  " <> hist)

    drivers =
      c
      |> Census.driver_types_over(t.lut_input_fanout[:warn])
      |> Enum.sort_by(fn {ty, n} -> {-n, ty} end)
      |> Enum.map_join("  ", fn {ty, n} -> "#{ty} #{n}" end)

    info.("drivers    (nets >#{t.lut_input_fanout[:warn]}) " <> drivers)

    cs = Census.control_set_summary(c)

    info.(
      "control    #{cs.sets} sets, #{cs.small_sets} under #{cs.small} FFs holding #{cs.ffs_in_small_sets} FFs"
    )
  end

  defp print_top(c, attr, n, info) do
    info.("")
    info.("top #{n} LUT-input nets")
    info.(lpad("lut", 6) <> lpad("ctl", 5) <> "  " <> pad("driver", 10) <> pad("block", 31) <> "net")

    c
    |> Census.top_nets(n)
    |> Enum.each(fn net ->
      net = explain(c, attr, net)
      info.(row(net))

      cond do
        net[:expr] -> info.("                                                   = " <> clip(net.expr, 100))
        net.name == nil and net[:signals] not in [nil, []] -> info.("                                                   <- " <> clip(Enum.join(net.signals, ", "), 100))
        true -> :ok
      end
    end)
  end

  defp print_blocks(c, attr, warn, n, info) do
    nets = Census.nets_over(c, warn)

    if nets != [] do
      info.("")
      info.("nets over #{warn} LUT inputs by instance prefix (nets, LUT inputs)")

      nets
      |> Enum.map(&explain(c, attr, &1))
      |> Enum.group_by(&(&1[:block] || "?"))
      |> Enum.map(fn {b, ns} -> {b, length(ns), ns |> Enum.map(& &1.lut) |> Enum.sum()} end)
      |> Enum.sort_by(fn {b, k, s} -> {-s, -k, b} end)
      |> Enum.take(n)
      |> Enum.each(fn {b, k, s} ->
        info.("  " <> pad(clip(b, 44), 46) <> lpad(k, 5) <> lpad(s, 8))
      end)
    end
  end

  defp print_findings(findings, t, info) do
    info.("")

    if findings == [] do
      info.("budget #{t.name}: ok")
    else
      info.("budget #{t.name}:")

      Enum.each(findings, fn f ->
        info.("  " <> pad(Atom.to_string(f.level), 9) <> pad(Atom.to_string(f.metric), 18) <> f.message)
      end)
    end
  end

  defp explain(_c, nil, net), do: Map.merge(net, %{label: net.name || "<#{net.driver_type || "?"} bit #{net.bit}>", block: nil})
  defp explain(c, attr, net), do: Attribution.explain(c, attr, net)

  defp row(net) do
    lpad(net.lut, 6) <>
      lpad(net.ctl, 5) <>
      "  " <>
      pad(net.driver_type || "?", 10) <>
      pad(clip(net[:block] || "?", 30), 31) <>
      clip(net.label, 60)
  end

  defp pad(s, w), do: String.pad_trailing(s, w)
  defp lpad(n, w), do: n |> to_string() |> String.pad_leading(w)

  defp clip(s, w) when byte_size(s) > w, do: binary_part(s, 0, w - 3) <> "..."
  defp clip(s, _w), do: s
end
