#!/usr/bin/env elixir
# ---------------------------------------------------------------------------
# export_usb_enum.exs
#
# Simulates USB host enumeration via the Rust NIF (fast path), captures the
# change log, and exports a DSView .dsl file.
#
# Usage:
#   mix run scripts/export_usb_enum.exs /tmp/usb_enum.dsl
# ---------------------------------------------------------------------------

alias Hw.Sim.{Nif, Compiler}
alias Hw.Sim.USBHost
alias Hw.Simtrace.DSL

out_path = System.argv() |> Enum.reject(&(&1 == "--")) |> List.first() || "/tmp/usb_enum.dsl"

IO.puts("==> Elaborating HelloBoard.Top...")
design   = Hw.elaborate(HelloBoard.Top)
schedule = Hw.Sim.Schedule.build(design)
compiled = Compiler.compile(schedule)

IO.puts("==> Compiling NIF automaton...")
{:ok, auto} = Nif.compile(compiled)

IO.puts("==> Running USB enumeration...")
changes = USBHost.enumerate(auto)
IO.puts("    #{length(changes)} change events recorded")

# ---------------------------------------------------------------------------
# Build DSL directly from NIF change log
# ---------------------------------------------------------------------------
# changes = [{time_ps, signal_atom, old_val, new_val}, ...]
# We need to reconstruct per-signal value timelines and pack to DSL format.

IO.puts("==> Building channel data from change log...")

# Signals we want to capture — map from DSL channel index to signal atom
channel_signals = %{
  0  => :dp_diff,            # host D+ raw (what USB decoder needs)
  1  => :dn_raw,             # host D- raw
  2  => :phy_tx_dp,          # FPGA TX D+
  3  => :phy_tx_dn,          # FPGA TX D-
  4  => :phy_rx_state,       # PHY RX state [0]
  5  => :phy_rx_state,       # PHY RX state [1]
  6  => :phy_rx_state,       # PHY RX state [2]
  7  => :sie_rx_state,       # SIE RX state [0]
  8  => :sie_rx_state,       # SIE RX state [1]
  9  => :sie_tx_state,       # SIE TX state [0]
  10 => :sie_tx_state,       # SIE TX state [1]
  11 => :sie_tx_state,       # SIE TX state [2]
  12 => :sie_send_handshake, # ACK/NAK trigger
  13 => :sie_ep_out_valid,   # EP OUT data valid
  14 => :cdc_dev_state,      # CDC dev state [0]
  15 => :cdc_dev_state,      # CDC dev state [1]
}

channel_bits = %{
  4 => 0, 5 => 1, 6 => 2,    # phy_rx_state bits
  7 => 0, 8 => 1,             # sie_rx_state bits
  9 => 0, 10 => 1, 11 => 2,  # sie_tx_state bits
  14 => 0, 15 => 1,           # cdc_dev_state bits
}

channel_names = %{
  0  => "dp_diff",   1  => "dn_raw",      2  => "tx_dp",     3  => "tx_dn",
  4  => "phy_rx[0]", 5 => "phy_rx[1]",   6  => "phy_rx[2]",
  7  => "sie_rx[0]", 8 => "sie_rx[1]",
  9  => "sie_tx[0]", 10 => "sie_tx[1]",  11 => "sie_tx[2]",
  12 => "send_hs",  13 => "ep_out_v",   14 => "dev_st[0]", 15 => "dev_st[1]",
}

samplerate  = 48_000_000
tick_ps     = trunc(1_000_000_000_000 / samplerate)

# Filter changes to only our signals of interest
wanted = MapSet.new(Map.values(channel_signals))
relevant = Enum.filter(changes, fn
  {_t, sig, _old, _new} -> MapSet.member?(wanted, sig)
  _ -> false
end)

IO.puts("    #{length(relevant)} relevant signal changes")

# Build per-signal value-at-time maps: %{signal => [{time_ps, value}]}
signal_timeline = Enum.reduce(relevant, %{}, fn {t, sig, _old, new}, acc ->
  Map.update(acc, sig, [{t, new}], &(&1 ++ [{t, new}]))
end)

# Get initial values from compiled schedule
signal_inits = Map.get(schedule, :signal_inits, %{})
get_init = fn sig -> Map.get(signal_inits, sig, 0) end

# For a given signal and time, find the most recent value
value_at = fn sig, t_ps ->
  case Map.get(signal_timeline, sig) do
    nil -> get_init.(sig)
    timeline ->
      timeline
      |> Enum.reduce({0, get_init.(sig)}, fn {ct, cv}, {bt, bv} ->
        if ct <= t_ps and ct >= bt, do: {ct, cv}, else: {bt, bv}
      end)
      |> elem(1)
  end
end

extract_bit = fn value, nil -> if value != 0, do: 1, else: 0
               value, bit  -> Bitwise.band(Bitwise.bsr(value, bit), 1) end

# Find time range from ALL changes (not just relevant ones)
all_times = Enum.map(changes, fn {t, _, _, _} -> t end)
first_ps  = Enum.min(all_times)
last_ps   = Enum.max(all_times)
num_ticks = div(last_ps - first_ps, tick_ps) + 1

IO.puts("    Time range: #{div(first_ps, 1000)}ns → #{div(last_ps, 1000)}ns (#{num_ticks} samples at 48MHz)")

# Pack each channel
ch_bins = Map.new(channel_signals, fn {ch_idx, sig} ->
  bit = Map.get(channel_bits, ch_idx)
  pad = rem(8 - rem(num_ticks, 8), 8)
  bytes =
    0..(num_ticks + pad - 1)
    |> Enum.chunk_every(8)
    |> Enum.map(fn chunk ->
      Enum.reduce(Enum.with_index(chunk), 0, fn {i, bit_pos}, acc ->
        t_ps = first_ps + i * tick_ps
        v = value_at.(sig, t_ps)
        b = extract_bit.(v, bit)
        Bitwise.bor(acc, Bitwise.bsl(b, bit_pos))
      end)
    end)
  {ch_idx, :erlang.list_to_binary(bytes)}
end)

# Build header
probe_lines = channel_names
  |> Enum.map_join("\n", fn {idx, name} -> "probe#{idx}=#{name}" end)

header = """
[version]
version=2

[header]
device mode=0
capturefile=L-0/0
samplerate=#{samplerate}
total samples=#{num_ticks}
total blocks=1
total probes=#{map_size(channel_signals)}
#{probe_lines}
"""

# Write ZIP
entries = [{~c"header", :erlang.iolist_to_binary(header)}] ++
  Enum.map(ch_bins, fn {idx, data} ->
    {String.to_charlist("L-#{idx}/0"), data}
  end)

case :zip.create(String.to_charlist(out_path), entries) do
  {:ok, _} ->
    IO.puts("""

==> Export complete!
    #{num_ticks} samples × #{map_size(channel_signals)} channels → #{out_path}

    DSView usage:
    1. Open #{out_path}
    2. Add decoder: Protocol → USB Full Speed
    3. Set DP = channel 0 (dp_diff), DM = channel 1 (dn_raw)
    4. Zoom to SET_ADDRESS packet to see enumeration flow
    """)
  {:error, reason} ->
    IO.puts("==> Export failed: #{inspect(reason)}")
    System.halt(1)
end
