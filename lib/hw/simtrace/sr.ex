defmodule Hw.Simtrace.SR do
  @moduledoc """
  Exports a simtrace recording as a sigrok `.sr` file for DSView/PulseView.

  The `.sr` format is a ZIP archive containing:
  - `version`  — ASCII "2"
  - `metadata` — INI file declaring samplerate, channel names, unitsize
  - `logic-1`  — raw binary: 2 bytes per sample, 1 bit per channel, 16 channels

  The 16-channel map is fixed for USB debugging:

      ch0   dp_diff              D+ (USB Full Speed decoder input)
      ch1   dn_raw               D- (USB Full Speed decoder input)
      ch2   phy_tx_en            PHY driving the bus
      ch3   phy_rx_active        SYNC detected, packet in progress
      ch4   phy_rx_valid         Valid bit from PHY
      ch5   phy_rx_se0           EOP / reset condition
      ch6   sie_send_handshake   SIE about to ACK or NAK
      ch7   sie_ep_out_valid     Byte delivered upstream to CDC
      ch8   sie_rx_state[0]      \\  SIE RX state machine (2-bit)
      ch9   sie_rx_state[1]       >  0=idle 1=recv_pid 2=recv_data 3=recv_token
      ch10  sie_tx_state[0]      \\
      ch11  sie_tx_state[1]       >  SIE TX state machine (3-bit)
      ch12  sie_tx_state[2]      /
      ch13  cdc_dev_state[0]     \\  CDC device state (2-bit)
      ch14  cdc_dev_state[1]      >  0=default 1=addressed 2=configured
      ch15  sie_ep_in_nak        NAK sent to host

  Load in DSView, run the USB Full Speed protocol decoder on ch0+ch1,
  then overlay the state machine channels to correlate decoded packets
  with internal state transitions.

  ## Usage

      {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
      st = Hw.Simtrace.attach(sim, filter: :usb)
      Hw.Sim.tick(sim, :clk_48, 5000)

      Hw.Simtrace.SR.export(st, "/tmp/usb_trace.sr")
      # Open /tmp/usb_trace.sr in DSView

  ## Samplerate

  The `.sr` file is written at 48 MHz — one sample per sim tick. If you
  ran ticks on `:clk_fast` (208 MHz) the file will still use 48 MHz since
  the PHY and SIE signals are synchronous to clk_48 in HelloBoard.Top.
  Pass `samplerate: 208_000_000` if you need otherwise.
  """

  alias Hw.Simtrace
  alias Hw.Simtrace.Query

  import Bitwise

  # Channel map: {channel_index, display_name, entity, signal, bit_index}
  # bit_index nil = use the signal value directly (1-bit signal)
  # bit_index n   = extract bit n from a multi-bit signal
  @channels [
    {0,  "dp_diff",           :phy, :phy_dp_diff,          nil},
    {1,  "dn_raw",            :phy, :phy_dn_raw,            nil},
    {2,  "tx_en",             :phy, :phy_tx_en,             nil},
    {3,  "rx_active",         :phy, :phy_rx_active,         nil},
    {4,  "rx_valid",          :phy, :phy_rx_valid,          nil},
    {5,  "rx_se0",            :phy, :phy_rx_se0,            nil},
    {6,  "send_handshake",    :sie, :sie_send_handshake,    nil},
    {7,  "ep_out_valid",      :sie, :sie_ep_out_valid,      nil},
    {8,  "rx_state[0]",       :sie, :sie_rx_state,          0},
    {9,  "rx_state[1]",       :sie, :sie_rx_state,          1},
    {10, "tx_state[0]",       :sie, :sie_tx_state,          0},
    {11, "tx_state[1]",       :sie, :sie_tx_state,          1},
    {12, "tx_state[2]",       :sie, :sie_tx_state,          2},
    {13, "dev_state[0]",      :cdc, :cdc_dev_state,         0},
    {14, "dev_state[1]",      :cdc, :cdc_dev_state,         1},
    {15, "ep_in_nak",         :sie, :sie_ep_in_nak,         nil},
  ]

  @default_samplerate 48_000_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Export the simtrace recording to a sigrok `.sr` file.

  ## Options

    * `:samplerate` — Hz, default 48_000_000 (48 MHz)
    * `:from`       — start time in ps (default: first recorded tick)
    * `:to`         — end time in ps (default: last recorded tick)

  ## Example

      Hw.Simtrace.SR.export(st, "/tmp/usb_trace.sr")
      Hw.Simtrace.SR.export(st, "/tmp/usb_trace.sr", samplerate: 48_000_000)
  """
  @spec export(Simtrace.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def export(%Simtrace{} = st, path, opts \\ []) do
    samplerate = Keyword.get(opts, :samplerate, @default_samplerate)

    # Build per-entity timelines once, then interleave by sim time
    timelines = build_timelines(st, opts)

    case timelines do
      {:error, reason} ->
        {:error, reason}

      samples when is_list(samples) ->
        n = length(samples)
        logic_binary = build_logic_binary(samples)
        metadata     = build_metadata(samplerate)

        case write_sr(path, metadata, logic_binary) do
          :ok              -> {:ok, %{samples: n, samplerate: samplerate, path: path}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Print the channel map to stdout — useful for configuring DSView.

      iex> Hw.Simtrace.SR.channels()
      ch0   dp_diff        phy  phy_dp_diff
      ch1   dn_raw         phy  phy_dn_raw
      ...
  """
  @spec channels() :: :ok
  def channels do
    IO.puts("")
    IO.puts("Channel map for DSView USB Full Speed decoder:")
    IO.puts("")
    Enum.each(@channels, fn {idx, name, entity, signal, bit} ->
      bit_str = if bit, do: " [bit #{bit}]", else: ""
      IO.puts(
        "  ch#{String.pad_leading(Integer.to_string(idx), 2)}  " <>
        String.pad_trailing(name, 18) <>
        String.pad_trailing(Atom.to_string(entity), 6) <>
        Atom.to_string(signal) <> bit_str
      )
    end)
    IO.puts("")
    IO.puts("DSView setup: run USB Full Speed decoder on ch0 (D+) and ch1 (D-)")
    IO.puts("")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Timeline building
  # ---------------------------------------------------------------------------

  # Build a merged, time-ordered list of {time_ps, %{signal => value}} maps.
  # One entry per unique sim timestamp across all entities.
  defp build_timelines(%Simtrace{} = st, opts) do
    # Load timelines for each entity that appears in the channel map
    entities = @channels |> Enum.map(fn {_, _, e, _, _} -> e end) |> Enum.uniq()

    # Check all required entities are traced
    missing = Enum.reject(entities, &(&1 in st.entity_names))
    if missing != [] do
      {:error, {:entities_not_traced, missing}}
    else
      # Get timelines filtered by time range
      tl_opts = Keyword.take(opts, [:from, :to])
      per_entity = Map.new(entities, fn entity ->
        tl = Query.timeline(st, entity, tl_opts)
        {entity, tl}
      end)

      # Collect all unique timestamps
      all_times = per_entity
        |> Enum.flat_map(fn {_, tl} -> Enum.map(tl, & &1.time_ps) end)
        |> Enum.uniq()
        |> Enum.sort()

      if all_times == [] do
        {:error, :no_data_recorded}
      else
        # For each timestamp, build a flat signal map by merging entity states
        # using the most recent snapshot at or before each time
        samples = Enum.map(all_times, fn t ->
          signal_map = Enum.reduce(entities, %{}, fn entity, acc ->
            state = Query.at(st, entity, t) || %{}
            Map.merge(acc, state)
          end)
          {t, signal_map}
        end)

        samples
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Binary packing
  # ---------------------------------------------------------------------------

  # Build the raw logic binary: 2 bytes per sample, little-endian.
  # Bit 0 of byte 0 = ch0, bit 7 of byte 0 = ch7,
  # bit 0 of byte 1 = ch8, bit 7 of byte 1 = ch15.
  defp build_logic_binary(samples) do
    for {_time_ps, signal_map} <- samples, into: <<>> do
      word = Enum.reduce(@channels, 0, fn {ch_idx, _name, _entity, signal, bit}, acc ->
        raw     = Map.get(signal_map, signal, 0)
        bit_val = extract_bit(raw, bit)
        bor(acc, bsl(band(bit_val, 1), ch_idx))
      end)

      <<band(word, 0xFF), band(bsr(word, 8), 0xFF)>>
    end
  end

  defp extract_bit(value, nil),   do: if(value != 0, do: 1, else: 0)
  defp extract_bit(value, bit_n), do: band(bsr(value, bit_n), 1)

  # ---------------------------------------------------------------------------
  # Metadata INI
  # ---------------------------------------------------------------------------

  defp build_metadata(samplerate) do
    probe_lines = Enum.map_join(@channels, "\n", fn {idx, name, _entity, _signal, _bit} ->
      "probe#{idx + 1}=#{name}"
    end)

    """
    [global]
    sigrok version=0.6.0

    [device 1]
    capturefile=logic-1
    unitsize=2
    total probes=16
    samplerate=#{samplerate} Hz
    #{probe_lines}
    """
  end

  # ---------------------------------------------------------------------------
  # ZIP writing
  # ---------------------------------------------------------------------------

  defp write_sr(path, metadata, logic_binary) do
    entries = [
      {~c"version",  <<"2">>},
      {~c"metadata", :erlang.iolist_to_binary(metadata)},
      {~c"logic-1",  logic_binary},
    ]

    case :zip.create(String.to_charlist(path), entries) do
      {:ok, _}         -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

end
