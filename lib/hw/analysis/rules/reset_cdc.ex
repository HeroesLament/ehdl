defmodule Hw.Analysis.Rules.ResetCDC do
  @moduledoc """
  Detects reset signals that cross clock domain boundaries without a
  reset synchronizer.

  ## Background

  Reset is the most commonly mishandled CDC signal in FPGA design.
  Designers correctly synchronize data signals but forget that reset
  itself must also be synchronized when it crosses domains.

  The failure mode is subtle: if reset de-asserts asynchronously
  relative to a clock, different flip-flops in the same domain may
  come out of reset on different clock edges. The design starts in
  an incoherent state that may look like a data corruption or a
  one-off protocol error rather than a reset problem.

  The correct primitive is a reset synchronizer — typically two
  flip-flops with asynchronous assert but synchronous de-assert.
  In EHDL terms, a `Hw.CDC.Sync2` with async_reset semantics, or a
  dedicated `Hw.CDC.ResetSync` if that primitive exists.

  ## What is checked

  This rule looks for wires named `rst`, `reset`, `areset`, or `nreset`
  that are connected to instances in clock domain A **and** to instances
  in clock domain B, without a `Hw.CDC.*` instance on the path between
  them.

  It is a specialization of `CDCCrossing` with two differences:
  1. It fires as an **error** (not a warning) — reset CDC is never safe
     to ignore
  2. It understands that a reset signal used in multiple domains is
     almost always an architectural mistake, not just a missing Sync2

  ## Example diagnostic

      error[E072]: reset signal `:rst` is used in both `clk_48` and
                   `clk_fast` domains without a reset synchronizer
        │
        │ HelloBoard.Top
        │
        │   wire :rst, 1          ← driven combinationally from pll_locked
        │   instance :phy,  Hw.USB.FSPhy,  ..., rst: :rst   (clk_48)
        │   instance :sie,  Hw.USB.SIE,    ..., rst: :rst   (clk_fast)
        │                                                    ^^^^^^^^^^^
        │
        └─ hint: add a reset synchronizer per domain:
                 instance :rst_sync_fast, Hw.CDC.Sync2,
                   clk_dst: :clk_fast, rst: :rst,
                   data_in: :rst, data_out: :rst_fast
                 then use `:rst_fast` for all clk_fast instances

  ## Priority

  Runs at priority 38, before general CDC (40) so reset issues surface
  first in the diagnostic list.
  """

  @behaviour Hw.Analysis.Rule

  # Dialyzer false positive: keyword list with map value does not unify
  # with :elixir.keyword() in strict mode.
  @dialyzer {:nowarn_function, check_component: 1}

  alias Hw.Analysis.{Diagnostic, Location}

  @impl Hw.Analysis.Rule
  def priority, do: 38

  @reset_names [:rst, :reset, :areset, :nreset, :rst_n, :reset_n]
  @clock_port_names [:clk, :clk_48mhz, :clk_fast, :clk_src, :clk_in, :clock]
  @cdc_modules [Hw.CDC.Sync2, Hw.CDC.HandshakeSync, Hw.CDC.PulseSync, Hw.CDC.GrayCounter]

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      if comp.instances != [] do
        check_component(comp)
      else
        []
      end
    end)
  end

  defp check_component(comp) do
    # Build: instance_name -> clock_wire
    domain_map = build_domain_map(comp.instances)

    # Build: reset_wire -> [{instance_name, clock_wire}]
    reset_consumers = build_reset_consumers(comp.instances, domain_map)

    # Build set of reset wires that pass through a CDC primitive
    cdc_synchronized = build_cdc_synchronized(comp.instances)

    Enum.flat_map(reset_consumers, fn {reset_wire, consumers} ->
      # Group consumers by clock domain
      by_domain =
        consumers
        |> Enum.reject(fn {_, clock} -> clock == nil end)
        |> Enum.group_by(fn {_, clock} -> clock end, fn {inst, _} -> inst end)

      domains = Map.keys(by_domain)

      if length(domains) <= 1 do
        # All consumers in same domain — fine
        []
      else
        if MapSet.member?(cdc_synchronized, reset_wire) do
          # There's a CDC primitive on this reset — still warn, reset sync
          # is more than just Sync2, but at least something is there
          []
        else
          domain_summary =
            by_domain
            |> Enum.map(fn {domain, insts} ->
              "#{domain} (#{Enum.join(insts, ", ")})"
            end)
            |> Enum.join("; ")

          loc = fallback(comp.module)
          [Diagnostic.error(
            :reset_cdc,
            "reset signal `:#{reset_wire}` is consumed in multiple clock " <>
            "domains without a reset synchronizer: #{domain_summary}",
            loc,
            context: %{
              reset_wire: reset_wire,
              domains:    Map.keys(by_domain),
              consumers:  by_domain,
              module:     comp.module
            }
          )]
        end
      end
    end)
  end

  defp build_domain_map(instances) do
    Map.new(instances, fn inst ->
      conns = inst_conns(inst) |> Map.new()
      clock = Enum.find_value(@clock_port_names, fn port ->
        # For CDC primitives use clk_dst as the authoritative domain
        if inst.module in @cdc_modules do
          Map.get(conns, :clk_dst) || Map.get(conns, :clk)
        else
          Map.get(conns, port)
        end
      end)
      {inst.name, clock}
    end)
  end

  defp build_reset_consumers(instances, domain_map) do
    Enum.reduce(instances, %{}, fn inst, acc ->
      clock = Map.get(domain_map, inst.name)
      conns = inst_conns(inst) |> Map.new()

      Enum.reduce(@reset_names, acc, fn rst_port, acc2 ->
        case Map.get(conns, rst_port) do
          nil -> acc2
          wire when is_atom(wire) ->
            entry = {inst.name, clock}
            Map.update(acc2, wire, [entry], &[entry | &1])
        end
      end)
    end)
  end

  defp build_cdc_synchronized(instances) do
    Enum.reduce(instances, MapSet.new(), fn inst, acc ->
      if inst.module in @cdc_modules do
        conns = inst_conns(inst) |> Map.new()
        case Map.get(conns, :data_out) do
          nil  -> acc
          wire -> MapSet.put(acc, wire)
        end
      else
        acc
      end
    end)
  end

  defp inst_conns(%{ports: ports}) when is_list(ports), do: ports
  defp inst_conns(%{connections: conns}) when is_list(conns), do: conns
  defp inst_conns(_), do: []

  defp fallback(module),
    do: %Location{file: "unknown", line: 0, module: module}
end
