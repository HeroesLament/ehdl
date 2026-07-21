defmodule Hw.Simtrace.DSL do
  @moduledoc """
  Exports a simtrace recording as a DSView `.dsl` file.

  This module is generic — it knows nothing about specific boards or protocols.
  You supply a channel map describing which signals to export. Board-specific
  presets live in `Hw.Simtrace.DSL.Presets`.

  ## DSView .dsl format (confirmed from DSView source: lib_main.c)

  The `.dsl` is a ZIP archive containing:

  - `header`   — INI file read by `sr_load_virtual_device_session`.
                 Must have `[version]` and `[header]` sections.
  - `L-0/0`    — Raw logic data for channel 0, block 0.
                 8 samples packed per byte, LSB = earliest sample.
  - `L-1/0`    — Raw logic data for channel 1, block 0.
  - ...
  - `L-N/0`    — Raw logic data for channel N, block 0.

  Each `L-{ch}/0` file contains only that channel's samples. DSView
  interleaves the channels at read time in 64-sample (8-byte) units.

  Required `[header]` keys:
  - `device mode`   — 0 = LOGIC
  - `capturefile`   — any value; its presence tells DSView this is version 2
  - `samplerate`    — integer Hz
  - `total samples` — integer sample count
  - `total blocks`  — number of block files per channel (we use 1)
  - `total probes`  — number of channels
  - `probe0` ... `probeN` — channel display names

  ## Channel map format

      [
        %{index: 0, name: "dp_diff",     entity: :phy, signal: :phy_dp_diff,   bit: nil},
        %{index: 1, name: "rx_state[0]", entity: :sie, signal: :sie_rx_state,  bit: 0},
        ...
      ]

  Fields:
  - `:index`  — DSView channel number, 0–15
  - `:name`   — label shown in DSView
  - `:entity` — sim entity atom (`:phy`, `:sie`, `:cdc`, etc.)
  - `:signal` — key in that entity's `reg_state` map
  - `:bit`    — `nil` for 1-bit signals, integer for multi-bit signals

  ## Usage

      channel_map = Hw.Simtrace.DSL.Presets.usb_full_speed()

      {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
      st = Hw.Simtrace.attach(sim)
      Hw.Sim.tick(sim, :clk_48, 5000)

      Hw.Simtrace.DSL.export(st, "/tmp/trace.dsl", channel_map)
      # => {:ok, %{samples: 5000, channels: 16, path: "/tmp/trace.dsl"}}

  ## Options

    * `:samplerate` — Hz, default 48_000_000
    * `:from`       — start time in ps (default: first recorded tick)
    * `:to`         — end time in ps (default: last recorded tick)
  """

  alias Hw.Simtrace
  alias Hw.Simtrace.Query

  import Bitwise

  @default_samplerate 48_000_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Export the simtrace recording to a DSView `.dsl` file.

  `channel_map` is a list of channel descriptors — see module doc for format.

  Returns `{:ok, %{samples: n, channels: n, path: path}}` on success.
  """
  @spec export(Simtrace.t(), Path.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def export(%Simtrace{} = st, path, channel_map, opts \\ []) do
    samplerate = Keyword.get(opts, :samplerate, @default_samplerate)

    with :ok            <- validate_channel_map(channel_map),
         {:ok, samples} <- build_samples(st, channel_map, Keyword.put(opts, :samplerate, samplerate)) do

      n       = length(samples)
      header  = build_header(samplerate, n, channel_map)
      ch_bins = pack_channels(samples, channel_map)

      case write_zip(path, header, ch_bins, channel_map) do
        :ok              -> {:ok, %{samples: n, channels: length(channel_map), path: path}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Print a channel map to stdout in a readable table.

      iex> Hw.Simtrace.DSL.print_channels(channel_map)
  """
  @spec print_channels([map()]) :: :ok
  def print_channels(channel_map) do
    IO.puts("")
    Enum.each(channel_map, fn ch ->
      bit_str = if ch.bit, do: " [bit #{ch.bit}]", else: ""
      IO.puts(
        "  ch#{String.pad_leading(Integer.to_string(ch.index), 2)}  " <>
        String.pad_trailing(ch.name, 18) <>
        String.pad_trailing(Atom.to_string(ch.entity), 8) <>
        Atom.to_string(ch.signal) <> bit_str
      )
    end)
    IO.puts("")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp validate_channel_map([]), do: {:error, :empty_channel_map}
  defp validate_channel_map(channel_map) do
    cond do
      length(channel_map) > 16 ->
        {:error, {:too_many_channels, length(channel_map)}}
      Enum.any?(channel_map, &(not Map.has_key?(&1, :index))) ->
        {:error, :missing_index_field}
      Enum.any?(channel_map, &(not Map.has_key?(&1, :signal))) ->
        {:error, :missing_signal_field}
      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Sample building — expand recorded transitions into one entry per tick
  # ---------------------------------------------------------------------------
  # ElixirScope only stores state when it changes (deduplication), so the
  # timeline has far fewer entries than ticks. We expand by:
  #   1. Getting the transition list (sparse)
  #   2. Computing tick_period_ps from the samplerate
  #   3. For each transition, holding that state for the correct number of
  #      ticks until the next transition timestamp
  # This gives one signal_map per DSView sample at exactly samplerate.

  defp build_samples(%Simtrace{} = st, channel_map, opts) do
    entities  = channel_map |> Enum.map(& &1.entity) |> Enum.uniq()
    samplerate = Keyword.get(opts, :samplerate, @default_samplerate)
    tick_ps    = trunc(1_000_000_000_000 / samplerate)  # ps per tick

    missing = Enum.reject(entities, &(&1 in st.entity_names))
    if missing != [] do
      {:error, {:entities_not_traced, missing}}
    else
      tl_opts = Keyword.take(opts, [:from, :to])

      # Get sparse transition list sorted by time
      transitions =
        entities
        |> Enum.flat_map(fn entity ->
          Query.timeline(st, entity, tl_opts) |> Enum.map(& &1.time_ps)
        end)
        |> Enum.uniq()
        |> Enum.sort()

      if transitions == [] do
        {:error, :no_data_recorded}
      else
        first_ps = List.first(transitions)
        last_ps  = List.last(transitions)

        # Snap first timestamp to a tick boundary
        first_tick_ps = trunc(first_ps / tick_ps) * tick_ps

        # Build a signal_map at each transition timestamp
        transition_states =
          Enum.map(transitions, fn t ->
            signal_map =
              Enum.reduce(entities, %{}, fn entity, acc ->
                Map.merge(acc, Query.at(st, entity, t) || %{})
              end)
            {t, signal_map}
          end)

        # Expand into one sample per tick from first to last tick
        last_tick  = trunc((last_ps - first_tick_ps) / tick_ps)
        num_ticks  = last_tick + 1

        samples =
          Enum.map(0..(num_ticks - 1), fn i ->
            t_ps = first_tick_ps + i * tick_ps
            # Find the most recent transition at or before this tick
            signal_map = latest_state_at(transition_states, t_ps)
            {t_ps, signal_map}
          end)

        {:ok, samples}
      end
    end
  end

  # Binary search for the latest transition at or before t_ps.
  # Falls back to the first entry if t_ps is before all transitions.
  defp latest_state_at(transitions, t_ps) do
    {_t, state} =
      Enum.reduce(transitions, hd(transitions), fn {t, state}, {best_t, best_state} ->
        if t <= t_ps and t >= best_t, do: {t, state}, else: {best_t, best_state}
      end)
    state
  end

  # ---------------------------------------------------------------------------
  # Per-channel binary packing
  # ---------------------------------------------------------------------------
  # Returns %{channel_index => binary}.
  # Each binary is the channel's samples packed 8-per-byte, LSB = earliest.
  # Sample count is padded up to a multiple of 8 (= one full byte).

  defp pack_channels(samples, channel_map) do
    pad    = rem(8 - rem(length(samples), 8), 8)
    padded = samples ++ List.duplicate({0, %{}}, pad)

    Map.new(channel_map, fn ch ->
      {ch.index, pack_one_channel(padded, ch)}
    end)
  end

  defp pack_one_channel(samples, ch) do
    samples
    |> Enum.map(fn {_t, signal_map} ->
      extract_bit(Map.get(signal_map, ch.signal, 0), ch.bit)
    end)
    |> Enum.chunk_every(8)
    |> Enum.map(fn bits ->
      # Pack 8 bits into one byte, bit 0 = first sample (LSB first)
      Enum.with_index(bits)
      |> Enum.reduce(0, fn {b, i}, acc -> bor(acc, bsl(band(b, 1), i)) end)
    end)
    |> :erlang.list_to_binary()
  end

  defp extract_bit(value, nil),   do: if(value != 0, do: 1, else: 0)
  defp extract_bit(value, bit_n), do: band(bsr(value, bit_n), 1)

  # ---------------------------------------------------------------------------
  # Header INI — parsed by DSView's sr_load_virtual_device_session
  # ---------------------------------------------------------------------------

  defp build_header(samplerate, num_samples, channel_map) do
    probe_lines =
      Enum.map_join(channel_map, "\n", fn ch ->
        "probe#{ch.index}=#{ch.name}"
      end)

    """
    [version]
    version=2

    [header]
    device mode=0
    capturefile=L-0/0
    samplerate=#{samplerate}
    total samples=#{num_samples}
    total blocks=1
    total probes=#{length(channel_map)}
    #{probe_lines}
    """
  end

  # ---------------------------------------------------------------------------
  # ZIP writing — one "L-{index}/0" entry per channel
  # ---------------------------------------------------------------------------

  defp write_zip(path, header, ch_bins, channel_map) do
    ch_entries =
      Enum.map(channel_map, fn ch ->
        name = String.to_charlist("L-#{ch.index}/0")
        {name, Map.get(ch_bins, ch.index, <<>>)}
      end)

    entries = [{~c"header", :erlang.iolist_to_binary(header)} | ch_entries]

    case :zip.create(String.to_charlist(path), entries) do
      {:ok, _}         -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
