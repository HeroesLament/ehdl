defmodule Hw.Sim.NifDSL do
  @moduledoc """
  Exports a Rust NIF simulation change log directly to a DSView `.dsl` file,
  bypassing ElixirScope and Simtrace entirely.

  The NIF `tick/3` call returns a change log — a list of
  `{time_ps, signal_name_atom, old_val, new_val}` tuples. This module
  reconstructs a full sample-per-tick waveform from those sparse transitions
  and packs it into the DSView ZIP format.

  ## Usage

      {:ok, auto} = Hw.Sim.Nif.compile(compiled)
      Hw.Sim.Nif.set_signal(auto, :dp_diff, 0)
      Hw.Sim.Nif.set_signal(auto, :dn_raw, 0)
      {:ok, c1} = Hw.Sim.Nif.tick(auto, :clk_48, 480_000)
      Hw.Sim.Nif.set_signal(auto, :dp_diff, 1)
      {:ok, c2} = Hw.Sim.Nif.tick(auto, :clk_48, 550_000)

      channel_map = Hw.Simtrace.DSL.Presets.usb_full_speed()
      Hw.Sim.NifDSL.export(c1 ++ c2, "/tmp/usb.dsl", channel_map)

  ## Channel map format

  Same format as `Hw.Simtrace.DSL` — a list of maps with keys:
  `:index`, `:name`, `:signal` (atom), `:bit` (nil or integer).

  ## Options

    * `:samplerate` — Hz, default 48_000_000
    * `:initial`    — map of `%{signal_atom => initial_value}` for signals
                      that don't appear in the change log (default: all 0)
  """

  import Bitwise

  @default_samplerate 48_000_000

  @doc """
  Export a NIF change log to a DSView `.dsl` file.

  `changes` is the concatenated output of one or more `Hw.Sim.Nif.tick/3` calls.
  `channel_map` is a list of channel descriptors (see module doc).

  Returns `{:ok, %{samples: n, channels: n, path: path}}`.
  """
  @spec export([tuple()], Path.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def export(changes, path, channel_map, opts \\ []) do
    samplerate = Keyword.get(opts, :samplerate, @default_samplerate)
    initial    = Keyword.get(opts, :initial, %{})
    tick_ps    = trunc(1_000_000_000_000 / samplerate)

    # Allow caller to specify full time range explicitly
    # (needed when most ticks have no signal changes)
    forced_start = Keyword.get(opts, :start_ps)
    forced_end   = Keyword.get(opts, :end_ps)

    sorted = Enum.sort_by(changes, &elem(&1, 0))

    {first_tick_ps, last_ps} = cond do
      forced_start != nil and forced_end != nil ->
        {trunc(forced_start / tick_ps) * tick_ps, forced_end}
      sorted == [] and forced_end != nil ->
        {0, forced_end}
      sorted == [] ->
        {:error, :no_changes}
      true ->
        first_ps = elem(hd(sorted), 0)
        last_ps  = forced_end || elem(List.last(sorted), 0)
        {trunc(first_ps / tick_ps) * tick_ps, last_ps}
    end

    if first_tick_ps == :error do
      {:error, :no_changes}
    else
      num_ticks = trunc((last_ps - first_tick_ps) / tick_ps) + 1

      # Build per-signal event list: %{signal_atom => [{time_ps, new_val}]}
      timeline =
        if sorted == [] do
          %{}
        else
          Enum.group_by(sorted, &elem(&1, 1), fn {t, _sig, _old, new} -> {t, new} end)
        end

      # Pack each channel
      ch_bins = Map.new(channel_map, fn ch ->
        events = Map.get(timeline, ch.signal, [])
        bin    = pack_channel(events, ch, first_tick_ps, tick_ps, num_ticks, initial)
        {ch.index, bin}
      end)

      case write_zip(path, samplerate, num_ticks, channel_map, ch_bins) do
        :ok              -> {:ok, %{samples: num_ticks, channels: length(channel_map), path: path}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Per-channel packing
  # ---------------------------------------------------------------------------

  defp pack_channel(events, ch, first_tick_ps, tick_ps, num_ticks, initial) do
    sorted_events = Enum.sort_by(events, &elem(&1, 0))
    initial_val   = Map.get(initial, ch.signal, 0)
    pad           = rem(8 - rem(num_ticks, 8), 8)
    total         = num_ticks + pad

    # Walk through ticks, tracking current signal value
    {bits, _val} =
      Enum.reduce(0..(total - 1), {[], initial_val}, fn i, {acc, cur_val} ->
        t_ps = first_tick_ps + i * tick_ps
        # Apply any events that occurred at exactly this tick
        new_val = Enum.reduce_while(sorted_events, cur_val, fn {et, ev}, acc_val ->
          cond do
            et <= t_ps -> {:cont, ev}
            true       -> {:halt, acc_val}
          end
        end)
        bit = extract_bit(new_val, ch.bit)
        {[bit | acc], new_val}
      end)

    bits
    |> Enum.reverse()
    |> Enum.chunk_every(8)
    |> Enum.map(fn chunk ->
      Enum.with_index(chunk)
      |> Enum.reduce(0, fn {b, i}, acc -> bor(acc, bsl(band(b, 1), i)) end)
    end)
    |> :erlang.list_to_binary()
  end

  defp extract_bit(value, nil),   do: if(value != 0, do: 1, else: 0)
  defp extract_bit(value, bit_n), do: band(bsr(value, bit_n), 1)

  # ---------------------------------------------------------------------------
  # ZIP writing — DSView .dsl format
  # ---------------------------------------------------------------------------

  defp write_zip(path, samplerate, num_samples, channel_map, ch_bins) do
    probe_lines =
      Enum.map_join(channel_map, "\n", fn ch -> "probe#{ch.index}=#{ch.name}" end)

    header = """
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
    ch_entries =
      Enum.map(channel_map, fn ch ->
        {String.to_charlist("L-#{ch.index}/0"), Map.get(ch_bins, ch.index, <<>>)}
      end)

    entries = [{~c"header", :erlang.iolist_to_binary(header)} | ch_entries]

    case :zip.create(String.to_charlist(path), entries) do
      {:ok, _}         -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
