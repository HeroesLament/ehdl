defmodule Hw.Sim.VCD do
  @moduledoc """
  VCD (Value Change Dump) writer for GTKWave visualization.

  VCD is a simple text format IEEE 1364:
    - Header with timescale and signal declarations
    - Stream of #timestamp markers and value changes

  Usage:
    {:ok, vcd} = Hw.Sim.VCD.start_link("trace.vcd", schedule)
    # ... run simulation ...
    Hw.Sim.VCD.flush(vcd)
    Hw.Sim.VCD.close(vcd)

  The VCD process subscribes to the State changes table and is
  called after each clock commit to drain and record changes.
  """

  use GenServer

  @timescale "1ps"

  defstruct [
    :file,        # IO device
    :sim_id,      # simulation instance ref
    :id_map,      # %{signal_name => vcd_id_string}
    :widths,      # %{signal_name => integer}
    :last_time,   # integer last emitted timestamp
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link({path, schedule, sim_id}) do
    GenServer.start_link(__MODULE__, {path, schedule, sim_id}, name: __MODULE__)
  end

  @doc "Drain pending changes from State and write to VCD file."
  def flush(time_ps) do
    GenServer.cast(__MODULE__, {:flush, time_ps})
  end

  @doc "Write final timestamp and close the file."
  def close do
    GenServer.call(__MODULE__, :close)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({path, schedule, sim_id}) do
    {:ok, file} = File.open(path, [:write])

    id_map = schedule.signal_widths
      |> Map.keys()
      |> Enum.with_index()
      |> Map.new(fn {name, idx} -> {name, encode_id(idx)} end)

    write_header(file, schedule, id_map)
    write_initial_values(file, id_map, schedule.signal_widths)

    state = %__MODULE__{
      file:      file,
      sim_id:    sim_id,
      id_map:    id_map,
      widths:    schedule.signal_widths,
      last_time: 0,
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:flush, time_ps}, state) do
    changes = Hw.Sim.State.drain_changes(state.sim_id)

    if Enum.any?(changes) do
      # Emit timestamp if it changed
      state = maybe_emit_timestamp(state, time_ps)

      # Emit each change
      Enum.each(changes, fn {name, value, _t} ->
        emit_change(state.file, name, value, state.id_map, state.widths)
      end)

      {:noreply, %{state | last_time: time_ps}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:close, _from, state) do
    IO.write(state.file, "##{state.last_time + 1}\n")
    File.close(state.file)
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # VCD writing helpers
  # ---------------------------------------------------------------------------

  defp write_header(file, schedule, id_map) do
    IO.write(file, "$timescale #{@timescale} $end\n")
    IO.write(file, "$scope module top $end\n")

    # Declare all signals grouped by entity prefix
    schedule.signal_widths
    |> Enum.sort_by(fn {name, _} -> Atom.to_string(name) end)
    |> Enum.each(fn {name, width} ->
      id = Map.fetch!(id_map, name)
      type = if width == 1, do: "wire", else: "wire"
      IO.write(file, "$var #{type} #{width} #{id} #{name} $end\n")
    end)

    IO.write(file, "$upscope $end\n")
    IO.write(file, "$enddefinitions $end\n")
    IO.write(file, "$dumpvars\n")
  end

  defp write_initial_values(file, id_map, widths) do
    widths
    |> Enum.sort_by(fn {name, _} -> Atom.to_string(name) end)
    |> Enum.each(fn {name, width} ->
      emit_change(file, name, 0, id_map, %{name => width})
    end)
    IO.write(file, "$end\n")
    IO.write(file, "#0\n")
  end

  defp maybe_emit_timestamp(state, time_ps) do
    if time_ps != state.last_time do
      IO.write(state.file, "##{time_ps}\n")
      %{state | last_time: time_ps}
    else
      state
    end
  end

  defp emit_change(file, name, value, id_map, widths) do
    id    = Map.get(id_map, name)
    width = Map.get(widths, name, 1)

    if id do
      if width == 1 do
        bit = if value != 0, do: "1", else: "0"
        IO.write(file, "#{bit}#{id}\n")
      else
        bits = Integer.to_string(value, 2) |> String.pad_leading(width, "0")
        IO.write(file, "b#{bits} #{id}\n")
      end
    end
  end

  # VCD signal IDs: printable ASCII from ! (33) upward
  # Wraps to multi-character IDs for large designs
  defp encode_id(n) do
    base = 94  # printable ASCII range

    if n < base do
      <<n + 33>>
    else
      # Multi-char ID for large signal counts
      digits = encode_base(n, base, [])
      Enum.map(digits, &(&1 + 33)) |> List.to_string()
    end
  end

  defp encode_base(0, _base, acc), do: acc
  defp encode_base(n, base, acc) do
    encode_base(div(n, base), base, [rem(n, base) | acc])
  end
end
