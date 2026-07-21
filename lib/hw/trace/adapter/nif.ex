defmodule Hw.Trace.Adapter.Nif do
  @moduledoc """
  Adapter from the Rust NIF backend to `Hw.Trace`.

  This is the engine-aware glue for the fast path: it builds a `Hw.Trace` from a
  `%Hw.Sim.Schedule{}` (mirroring `Hw.Waveform.new/2`'s signal selection and
  metadata resolution) and folds the backend's `step/3` output into it via the
  two `Hw.Trace` fold functions.

  The Rust kernel is untouched — this only reshapes what it already emits:

    * `step_wave/4`      — one sample per *batch* of edges, from the sparse
      `{time_ps, sig, old, new}` change log (`Trace.apply_delta/3`).
    * `step_wave_each/4` — one sample per *edge*, via a full snapshot so that
      combinational signals (absent from the sparse log) are captured
      (`Trace.apply_snapshot/3`).

  Both mirror `Hw.Sim.Backend.step_wave*/4` exactly, so a `Trace` reproduces
  what `%Hw.Waveform{}` records from the same run — the M2 characterization gate.
  """

  alias Hw.Sim.{Backend, Schedule}
  alias Hw.Trace

  @doc """
  Build an empty `Hw.Trace` over a schedule's signals.

  ## Options (mirror `Hw.Waveform.new/2`)
    * `:signals` — `:ports` (default), `:all`, or an explicit `[atom()]` list.
    * `:clock`   — clock atom defining the index axis (default: first clock).
    * `:display` — keyword list of `{signal_atom, hint}` overrides.
  """
  @spec new(Schedule.t(), keyword()) :: Trace.t()
  def new(%Schedule{} = schedule, opts \\ []) do
    signal_filter = Keyword.get(opts, :signals, :ports)
    display_opts = Keyword.get(opts, :display, [])
    clock = Keyword.get(opts, :clock, first_clock(schedule))

    selected = select_signals(schedule, signal_filter)
    inits = Map.get(schedule, :signal_inits, %{})

    specs =
      Enum.map(selected, fn name ->
        width = Map.get(schedule.signal_widths, name, 1)

        fields = %{
          width: width,
          hint: Keyword.get(display_opts, name, nil),
          init: Map.get(inits, name, 0),
          domain: domain_of(schedule, name)
        }

        # nil hint => let Trace.new default from width (same rule as Hw.Waveform)
        fields = if is_nil(fields.hint), do: Map.delete(fields, :hint), else: fields
        {name, fields}
      end)

    Trace.new(specs, clock: clock)
  end

  @doc """
  Step `n` edges, recording ONE sample from the batch's sparse change log.

  Mirrors `Hw.Sim.Backend.step_wave/4`. Returns `{sim, trace}`.
  """
  @spec step_wave(term(), Trace.t(), atom(), pos_integer()) ::
          {term(), Trace.t()} | {:error, term()}
  def step_wave(sim, %Trace{} = trace, clock, n \\ 1) do
    case Backend.step(sim, clock, n) do
      {:ok, updated_sim, changes} ->
        {updated_sim, Trace.apply_delta(trace, changes)}

      err ->
        err
    end
  end

  @doc """
  Step `n` edges, recording one sample PER edge via a full snapshot.

  Mirrors `Hw.Sim.Backend.step_wave_each/4` — combinational signals are captured
  because the snapshot is dense. Returns `{sim, trace}`.
  """
  @spec step_wave_each(term(), Trace.t(), atom(), pos_integer()) ::
          {term(), Trace.t()} | {:error, term()}
  def step_wave_each(sim, %Trace{} = trace, clock, n) do
    Enum.reduce_while(1..n, {sim, trace}, fn _, {s, t} ->
      case Backend.step(s, clock, 1) do
        {:ok, updated_sim, _changes} ->
          case Backend.snapshot(updated_sim) do
            {:ok, snap} ->
              {:cont, {updated_sim, Trace.apply_snapshot(t, snap, t.last_time_ps)}}

            {:error, _} ->
              {:cont, {updated_sim, Trace.apply_delta(t, [])}}
          end

        err ->
          {:halt, err}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private — selection/meta, mirroring Hw.Waveform's private helpers
  # ---------------------------------------------------------------------------

  defp select_signals(%Schedule{} = schedule, :ports) do
    all = Map.keys(schedule.signal_widths)

    ports =
      Enum.reject(all, fn name ->
        str = Atom.to_string(name)

        known_prefixes = [
          "phy_",
          "sie_",
          "cdc_",
          "uart_tx_",
          "uart_rx_",
          "rst_sync_",
          "axi_",
          "spi_"
        ]

        Enum.any?(known_prefixes, &String.starts_with?(str, &1))
      end)

    if Enum.empty?(ports), do: all, else: Enum.sort(ports)
  end

  defp select_signals(%Schedule{} = schedule, :all) do
    schedule.signal_widths |> Map.keys() |> Enum.sort()
  end

  defp select_signals(%Schedule{}, signals) when is_list(signals), do: signals

  defp domain_of(%Schedule{entities: entities}, signal_name) do
    str = Atom.to_string(signal_name)

    case Enum.find(entities, fn {_name, entity} ->
           String.starts_with?(str, Atom.to_string(entity.name) <> "_")
         end) do
      {_, entity} -> entity.domain
      nil -> nil
    end
  end

  defp first_clock(%Schedule{clocks: [clk | _]}), do: clk.name
  defp first_clock(_), do: nil
end
