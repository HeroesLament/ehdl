defmodule Hw.Trace.VCD do
  @moduledoc """
  Hierarchical VCD (Value Change Dump) export from a `Hw.Trace`.

  Unlike the flat single-`$scope module top` export in `Hw.Waveform.to_vcd/2`,
  this emits real `$scope`/`$upscope` nesting derived from the trace's scope
  tree — so GTKWave / Surfer show the design hierarchy (`top`, `sie`, `cdc`, …)
  in their signal browser instead of one undifferentiated list. This is what
  Hardcaml and the VCD spec both model: a signal is `scope-path + leaf`.

  It also fixes two defects carried by the old generator:

    * The no-op `type = if width == 1, do: "wire", else: "wire"` — VCD `$var`
      type now distinguishes registers (`reg`) from combinational nets (`wire`),
      using each signal's domain (registered signals belong to a clock domain).
    * A single flat scope — replaced by true nesting.
  """

  alias Hw.Trace

  @doc """
  Render a `Hw.Trace` to a VCD string.

  ## Options
    * `:signals` — limit to these signal refs (default: all tracked).
  """
  @spec to_vcd(Trace.t(), keyword()) :: String.t()
  def to_vcd(%Trace{} = trace, opts \\ []) do
    metas = selected_metas(trace, Keyword.get(opts, :signals))

    id_map =
      metas
      |> Enum.sort_by(& &1.addr)
      |> Enum.with_index()
      |> Map.new(fn {m, i} -> {m.addr, vcd_id(i)} end)

    IO.iodata_to_binary([
      header(metas, id_map),
      body(trace, metas, id_map)
    ])
  end

  # ---------------------------------------------------------------------------
  # Header — nested $scope / $upscope from the scope tree
  # ---------------------------------------------------------------------------

  defp header(metas, id_map) do
    # group signals by their (single-level) scope path head
    by_scope =
      metas
      |> Enum.group_by(fn %{addr: {scope, _leaf}} -> List.first(scope) end)
      |> Enum.sort_by(fn {scope, _} -> Atom.to_string(scope) end)

    scope_blocks =
      Enum.map(by_scope, fn {scope, group} ->
        decls =
          group
          |> Enum.sort_by(& &1.addr)
          |> Enum.map(fn m ->
            {_scope, leaf} = m.addr
            "$var #{vcd_type(m)} #{m.width} #{id_map[m.addr]} #{leaf} $end\n"
          end)

        ["$scope module #{scope} $end\n", decls, "$upscope $end\n"]
      end)

    inits =
      metas
      |> Enum.sort_by(& &1.addr)
      |> Enum.map(fn m -> vcd_value_line(m.init, m.width, id_map[m.addr]) end)

    [
      "$timescale 1ps $end\n",
      scope_blocks,
      "$enddefinitions $end\n",
      "$dumpvars\n",
      inits,
      "$end\n",
      "#0\n"
    ]
  end

  # A registered signal (has a clock domain) is a `reg`; pure combinational
  # nets are `wire`. This is the fix for the old no-op conditional.
  defp vcd_type(%{domain: d}) when not is_nil(d), do: "reg"
  defp vcd_type(_), do: "wire"

  # ---------------------------------------------------------------------------
  # Body — timestamped value changes
  # ---------------------------------------------------------------------------

  defp body(trace, metas, id_map) do
    tracked = MapSet.new(metas, & &1.addr)
    width_of = Map.new(metas, &{&1.addr, &1.width})

    {lines, _prev} =
      trace
      |> Trace.samples()
      |> Enum.reduce({[], %{}}, fn sample, {acc, prev} ->
        changes =
          sample.values
          |> Enum.filter(fn {addr, val} ->
            MapSet.member?(tracked, addr) and Map.get(prev, addr) != val
          end)
          |> Enum.sort_by(fn {addr, _} -> addr end)
          |> Enum.map(fn {addr, val} ->
            vcd_value_line(val, width_of[addr], id_map[addr])
          end)

        if changes == [] do
          {acc, prev}
        else
          {acc ++ ["##{sample.time_ps}\n" | changes], Map.merge(prev, sample.values)}
        end
      end)

    lines
  end

  # ---------------------------------------------------------------------------
  # VCD encoding primitives (shared shape with Hw.Waveform's, retained)
  # ---------------------------------------------------------------------------

  defp vcd_value_line(val, 1, id) do
    bit = if val != 0, do: "1", else: "0"
    "#{bit}#{id}\n"
  end

  defp vcd_value_line(val, w, id) do
    bits = Integer.to_string(val, 2) |> String.pad_leading(w, "0")
    "b#{bits} #{id}\n"
  end

  defp vcd_id(n) do
    base = 94

    if n < base do
      <<n + 33>>
    else
      Stream.iterate(n, &div(&1, base))
      |> Stream.take_while(&(&1 > 0))
      |> Enum.map(&(rem(&1, base) + 33))
      |> List.to_string()
    end
  end

  defp selected_metas(trace, nil), do: Map.values(trace.signals)

  defp selected_metas(trace, refs) when is_list(refs) do
    refs
    |> Enum.map(&Trace.meta(trace, &1))
    |> Enum.reject(&is_nil/1)
  end
end
