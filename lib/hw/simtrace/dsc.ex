defmodule Hw.Simtrace.DSC do
  @moduledoc """
  Generates a DSView `.dsc` session config file to accompany a `.dsl` export.

  A `.dsc` is a plain JSON file that DSView loads via File > Load Session.
  It pre-configures channel names, colours, and device settings so you don't
  have to rename all 16 channels by hand after opening the `.dsl`.

  The decoder array is left empty — DSView's decoder config format is not
  documented and varies by version. Add the USB Full Speed decoder manually
  once, then use File > Store Session to save a fully-configured `.dsc` for
  future reuse.

  ## Usage

      channel_map = Hw.Simtrace.DSL.Presets.usb_full_speed()

      # Export data
      Hw.Simtrace.DSL.export(st, "/tmp/usb.dsl", channel_map)

      # Export matching config — load this in DSView via File > Load Session
      Hw.Simtrace.DSC.export(channel_map, "/tmp/usb.dsc",
        samplerate: 1_000_000,
        device: "DSLogic"
      )

  ## Options

    * `:device`      — device string written to config (default: `"DSLogic"`)
    * `:samplerate`  — integer Hz (default: `1_000_000`)
    * `:num_channels`— total channels declared, must be >= length(channel_map)
                       (default: 16)
  """

  @default_device     "DSLogic"
  @default_samplerate 1_000_000
  @default_channels   16
  @channel_type_logic 10000

  @doc """
  Write a `.dsc` config file for the given channel map.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec export([map()], Path.t(), keyword()) :: :ok | {:error, term()}
  def export(channel_map, path, opts \\ []) do
    device      = Keyword.get(opts, :device,       @default_device)
    samplerate  = Keyword.get(opts, :samplerate,   @default_samplerate)
    num_channels = Keyword.get(opts, :num_channels, @default_channels)

    json = build_dsc(channel_map, device, samplerate, num_channels)

    case File.write(path, json) do
      :ok              -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # JSON construction
  # ---------------------------------------------------------------------------

  defp build_dsc(channel_map, device, samplerate, num_channels) do
    # Build a lookup from index -> channel entry for named channels
    named = Map.new(channel_map, fn ch -> {ch.index, ch} end)

    # Emit all num_channels entries — named ones get label+colour, others default
    channels = Enum.map(0..(num_channels - 1), fn idx ->
      case Map.get(named, idx) do
        nil ->
          default_channel(idx)
        ch ->
          named_channel(idx, ch.name, Map.get(ch, :colour))
      end
    end)

    trigger_blocks = build_trigger_blocks(num_channels)

    doc = %{
      "Channel Mode"            => 0,
      "CollectMode"             => 0,
      "Device"                  => device,
      "DeviceMode"              => 0,
      "Enable RLE Compress"     => 0,
      "Filter Targets"          => 0,
      "Horizontal trigger position" => 0,
      "Language"                => 31,
      "Max Height"              => "1X",
      "Operation Mode"          => 1,
      "Sample count"            => "1000448",
      "Sample rate"             => Integer.to_string(samplerate),
      "Stop Options"            => 1,
      "Threshold Level"         => "1",
      "Title"                   => "DSView",
      "Trigger channel"         => 0,
      "Trigger hold off"        => "0",
      "Trigger margin"          => 8,
      "Trigger slope"           => 0,
      "Trigger source"          => 0,
      "Using Clock Negedge"     => 0,
      "Using External Clock"    => 0,
      "Version"                 => 3,
      "channel"                 => channels,
      "decoder"                 => [],
      "trigger"                 => trigger_blocks,
    }

    JSON.encode!(doc)
  end

  defp default_channel(idx) do
    %{
      "colour"     => "default",
      "enabled"    => true,
      "index"      => idx,
      "name"       => Integer.to_string(idx),
      "strigger"   => 0,
      "type"       => @channel_type_logic,
      "view_index" => idx,
    }
  end

  defp named_channel(idx, name, colour) do
    %{
      "colour"     => colour || "default",
      "enabled"    => true,
      "index"      => idx,
      "name"       => name,
      "strigger"   => 0,
      "type"       => @channel_type_logic,
      "view_index" => idx,
    }
  end

  # ---------------------------------------------------------------------------
  # Trigger block — boilerplate matching DSView's default .dsc
  # ---------------------------------------------------------------------------

  defp build_trigger_blocks(num_channels) do
    # Stage trigger fields are indexed 0..(num_channels-1)
    stage_fields = Enum.reduce(0..(num_channels - 1), %{}, fn i, acc ->
      suffix = Integer.to_string(i)
      acc
      |> Map.put("stageTriggerContiguous#{suffix}", false)
      |> Map.put("stageTriggerCount#{suffix}",      1)
      |> Map.put("stageTriggerInv0#{suffix}",       0)
      |> Map.put("stageTriggerInv1#{suffix}",       0)
      |> Map.put("stageTriggerLogic#{suffix}",      1)
      |> Map.put("stageTriggerValue0#{suffix}",     x_string(num_channels))
      |> Map.put("stageTriggerValue1#{suffix}",     x_string(num_channels))
    end)

    base = %{
      "advTriggerMode"        => false,
      "serialTriggerBits"     => 0,
      "serialTriggerChannel"  => 0,
      "serialTriggerClock"    => x_string(num_channels),
      "serialTriggerData"     => x_string(num_channels),
      "serialTriggerStart"    => x_string(num_channels),
      "serialTriggerStop"     => x_string(num_channels),
      "triggerPos"            => 1,
      "triggerStages"         => 0,
      "triggerTab"            => 0,
    }

    Map.merge(base, stage_fields)
  end

  # "X X X X ..." with one X per channel
  defp x_string(n), do: Enum.join(List.duplicate("X", n), " ")
end
