defmodule Hw.Simtrace do
  @moduledoc """
  IEx-friendly waveform tracing for EHDL simulations.

  Attaches non-invasively to a running simulation via `:sys.trace` —
  no changes to Hw.Sim or your design modules required. Requires
  `:elixir_scope` as an optional dep.

  ## Quickstart

      {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
      st = Hw.Simtrace.attach(sim)

      Hw.Sim.tick(sim, :clk_48, 2000)

      Hw.Simtrace.signals(st)
      Hw.Simtrace.waveform(st, :sie, [:rx_state, :tx_state], ticks: 20)
      Hw.Simtrace.find_when(st, :sie, rx_state: 2)
      Hw.Simtrace.at(st, :cdc, 104)
      Hw.Simtrace.diff(st, :sie, 100, 208)

  ## The `st` handle

  `attach/2` returns a `%Hw.Simtrace{}` struct. Pass it to every query.
  It is read-only — the underlying sim runs independently.

  ## Time units

  All timestamps are in picoseconds matching the sim clock. For a 48 MHz
  clock, one tick = 20,833 ps. Use `Hw.Simtrace.ps_per_tick/2` to convert.
  """

  alias Hw.Simtrace.{Attach, Query, Waveform}

  @derive {Inspect, only: [:sim_id, :entity_names, :watchers]}
  defstruct [:sim_id, :schedule, :watchers, :entity_names]

  @type t :: %__MODULE__{
    sim_id:       reference(),
    schedule:     map(),
    watchers:     %{atom() => pid()},
    entity_names: [atom()],
  }

  # ---------------------------------------------------------------------------
  # Attach
  # ---------------------------------------------------------------------------

  @doc """
  Attach simtrace to a running simulation.

  Spawns one external watcher per entity. Each watcher uses `:sys.trace`
  to intercept `{:commit, time_ps}` messages and snapshots the entity's
  `reg_state` map into ElixirScope's TraceDB at the sim picosecond time.

  ## Options

    * `:entities` — list of entity atoms to trace. Default: all entities
      in the sim (`:phy`, `:sie`, `:cdc`, `:uart_tx`, etc.)
    * `:filter` — `:all` (default) or `:usb` (only `:phy`, `:sie`, `:cdc`)

  ## Examples

      st = Hw.Simtrace.attach(sim)
      st = Hw.Simtrace.attach(sim, filter: :usb)
      st = Hw.Simtrace.attach(sim, entities: [:sie, :cdc])
  """
  @spec attach(map(), keyword()) :: t()
  def attach(sim, opts \\ []) do
    Attach.attach(sim, opts)
  end

  @doc """
  Detach all watchers and stop tracing. The sim continues running.
  Recorded history remains queryable until ElixirScope is stopped.
  """
  @spec detach(t()) :: :ok
  def detach(%__MODULE__{watchers: watchers}) do
    Attach.detach(watchers)
  end

  @doc """
  Materialize a unified `Hw.Trace` from this Simtrace's recorded history.

  This is the bridge into the unified trace subsystem: it folds every traced
  entity's per-commit `reg_state` timeline (from ElixirScope's TraceDB) into one
  `Hw.Trace`, which you can then query with `Hw.Trace.Query` and render with
  `Hw.Trace.Render` — the same verbs that work on NIF-backed traces, now over a
  live-engine recording.

  The entity-scoped `Hw.Simtrace.*` verbs (`timeline/3`, `find_when/3`, …)
  continue to work as before; this simply offers the unified path alongside them.

      iex> st = Hw.Simtrace.attach(sim, filter: :usb)
      iex> Hw.Sim.tick(sim, :clk_48, 2000)
      iex> trace = Hw.Simtrace.to_trace(st)
      iex> Hw.Trace.Query.find_when(trace, [scope: :sie], rx_state: 2)
      iex> Hw.Trace.Query.find_when(trace, [], "top.dev_addr": 1)   # cross-scope
  """
  @spec to_trace(t()) :: Hw.Trace.t()
  def to_trace(%__MODULE__{} = st) do
    Hw.Trace.Adapter.Live.from_history(st)
  end

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  @doc """
  List all traced entities and their register names.

      iex> Hw.Simtrace.signals(st)
      %{
        phy: [:phase, :rx_state, :tx_state, :rx_ones, :tx_ones, :prev_diff,
              :tx_dp, :tx_dn],
        sie: [:rx_state, :tx_state, :bit_cnt, :byte_shift, :rx_pid, :crc16_reg,
              :crc5_reg, :sync_cnt, :send_handshake, :token_ep_reg, ...],
        cdc: [:dev_state, :ep0_state, :dev_addr, :setup_b0, :setup_b1, ...]
      }
  """
  @spec signals(t()) :: %{atom() => [atom()]}
  def signals(%__MODULE__{} = st) do
    Query.signals(st)
  end

  @doc """
  Print a compact summary of recorded trace data to stdout. Returns `:ok`.
  This is the primary way to check what's been captured — never dumps raw data.

      iex> Hw.Simtrace.info(st)

      Simtrace  sim=#Reference<0.4.0.1>  entities: [:cdc, :phy, :sie]

      entity   ticks   from          to
      ──────────────────────────────────────────
      cdc         10   0ps           208_330ps
      phy         10   0ps           208_330ps
      sie         10   0ps           208_330ps
  """
  @spec info(t()) :: :ok
  def info(%__MODULE__{} = st) do
    IO.puts("")
    IO.puts("Simtrace  sim=#{inspect(st.sim_id)}  entities: #{inspect(st.entity_names)}")
    IO.puts("")

    rows = Enum.map(st.entity_names, fn name ->
      case Query.recorded_summary(st, name) do
        %{ticks: 0} ->
          {name, "0", "(no data)", "(no data)"}
        %{ticks: n, first_ps: f, last_ps: l} ->
          {name, Integer.to_string(n), fmt_ps(f), fmt_ps(l)}
      end
    end)

    col1 = max(10, Enum.map(rows, fn {n, _, _, _} -> String.length(Atom.to_string(n)) end) |> Enum.max())
    IO.puts(String.pad_trailing("entity", col1) <> "   ticks   from              to")
    IO.puts(String.duplicate("─", col1 + 36))
    Enum.each(rows, fn {name, ticks, from, to} ->
      IO.puts(
        String.pad_trailing(Atom.to_string(name), col1) <> "   " <>
        String.pad_leading(ticks, 5) <> "   " <>
        String.pad_trailing(from, 16) <> "  " <> to
      )
    end)
    IO.puts("")
    :ok
  end

  # ---------------------------------------------------------------------------
  # DSL export
  # ---------------------------------------------------------------------------

  @doc """
  Export the recording as a DSView `.dsl` file.

  `channel_map` is a list of channel descriptors mapping sim signals to DSView
  channels. Use `Hw.Simtrace.DSL.Presets.usb_full_speed/0` for a ready-made
  USB map, or build your own for other protocols.

      channel_map = Hw.Simtrace.DSL.Presets.usb_full_speed()
      Hw.Simtrace.export_dsl(st, "/tmp/trace.dsl", channel_map)
      # => {:ok, %{samples: 5000, channels: 16, path: "/tmp/trace.dsl"}}

  ## Options

    * `:samplerate` — Hz, default 48_000_000
    * `:from`       — start time in ps
    * `:to`         — end time in ps
  """
  @spec export_dsl(t(), Path.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def export_dsl(%__MODULE__{} = st, path, channel_map, opts \\ []) do
    Hw.Simtrace.DSL.export(st, path, channel_map, opts)
  end

  @doc """
  Print the channel map table to stdout.

      iex> Hw.Simtrace.print_channels(Hw.Simtrace.DSL.Presets.usb_full_speed())
  """
  @spec print_channels([map()]) :: :ok
  def print_channels(channel_map) do
    Hw.Simtrace.DSL.print_channels(channel_map)
  end

  @doc """
  Write a DSView `.dsc` session config file for a channel map.

  Load this in DSView via **File > Load Session** after opening the `.dsl`
  to get channel names and colours pre-configured. Then add the USB Full
  Speed decoder on ch0/ch1 manually once and use **File > Store Session**
  to save a fully-configured `.dsc` for future reuse.

      channel_map = Hw.Simtrace.DSL.Presets.usb_full_speed()
      Hw.Simtrace.export_dsc(channel_map, "/tmp/usb.dsc")
      # => :ok

  ## Options

    * `:device`      — device string (default: `"DSLogic"`)
    * `:samplerate`  — Hz (default: `1_000_000`)
    * `:num_channels`— total channel count to declare (default: 16)
  """
  @spec export_dsc([map()], Path.t(), keyword()) :: :ok | {:error, term()}
  def export_dsc(channel_map, path, opts \\ []) do
    Hw.Simtrace.DSC.export(channel_map, path, opts)
  end


  def export_sr(%__MODULE__{} = st, path, opts \\ []) do
    channel_map = Hw.Simtrace.DSL.Presets.usb_full_speed()
    Hw.Simtrace.DSL.export(st, path, channel_map, opts)
  end

  @doc false
  @deprecated "Use print_channels/1 instead"
  def sr_channels, do: Hw.Simtrace.DSL.print_channels(Hw.Simtrace.DSL.Presets.usb_full_speed())


  defp fmt_ps(ps) when ps >= 1_000_000,     do: "#{Float.round(ps / 1_000_000, 2)}μs"
  defp fmt_ps(ps) when ps >= 1_000,         do: "#{Float.round(ps / 1_000, 2)}ns"
  defp fmt_ps(ps),                           do: "#{ps}ps"



  @doc """
  Number of picoseconds per tick for a given clock.
  Useful for converting `at/3` timestamps.

      iex> Hw.Simtrace.ps_per_tick(st, :clk_48)
      20_833
  """
  @spec ps_per_tick(t(), atom()) :: non_neg_integer()
  def ps_per_tick(%__MODULE__{} = st, clock_name) do
    Query.ps_per_tick(st, clock_name)
  end

  # ---------------------------------------------------------------------------
  # Point-in-time queries
  # ---------------------------------------------------------------------------

  @doc """
  Full register snapshot for an entity at or just before `time_ps`.

      iex> Hw.Simtrace.at(st, :sie, 104)
      %{
        rx_state: 2,
        tx_state: 0,
        bit_cnt: 3,
        crc16_reg: 0xB001,
        rx_pid: 0x69,
        token_ep_reg: 1,
        token_is_in_reg: 1,
        send_handshake: 0,
        ...
      }

  Pass `:last` to get the most recent snapshot:

      iex> Hw.Simtrace.at(st, :cdc, :last)
  """
  @spec at(t(), atom(), non_neg_integer() | :last) :: map() | nil
  def at(%__MODULE__{} = st, entity, time_ps) do
    Query.at(st, entity, time_ps)
  end

  @doc """
  Get the value of a single register at a given sim time.

      iex> Hw.Simtrace.get(st, :sie, :rx_state, 104)
      2

      iex> Hw.Simtrace.get(st, :cdc, :dev_state, :last)
      2
  """
  @spec get(t(), atom(), atom(), non_neg_integer() | :last) :: integer() | nil
  def get(%__MODULE__{} = st, entity, register, time_ps) do
    Query.get(st, entity, register, time_ps)
  end

  # ---------------------------------------------------------------------------
  # Timeline queries
  # ---------------------------------------------------------------------------

  @doc """
  Full timeline of register snapshots for an entity, ordered by sim time.

      iex> Hw.Simtrace.timeline(st, :sie)
      [
        %{time_ps: 0,    state: %{rx_state: 0, tx_state: 0, ...}},
        %{time_ps: 20833, state: %{rx_state: 0, tx_state: 0, ...}},
        %{time_ps: 41666, state: %{rx_state: 1, tx_state: 0, ...}},
        ...
      ]

  ## Options

    * `:from` — start time in ps (inclusive)
    * `:to`   — end time in ps (inclusive)
    * `:only` — list of register atoms to include in each snapshot
  """
  @spec timeline(t(), atom(), keyword()) :: [map()]
  def timeline(%__MODULE__{} = st, entity, opts \\ []) do
    Query.timeline(st, entity, opts)
  end

  @doc """
  Find all ticks where one or more registers held specific values.
  Returns timeline entries (with full state snapshot) where ALL
  conditions matched.

      # When did the SIE first receive an IN token?
      iex> Hw.Simtrace.find_when(st, :sie, rx_state: 2, token_is_in_reg: 1)
      [%{time_ps: 104, state: %{...}}, ...]

      # When was CDC in addressed state?
      iex> Hw.Simtrace.find_when(st, :cdc, dev_state: 1)

  Accepts a function for custom conditions:

      iex> Hw.Simtrace.find_when(st, :sie, fn s -> s.crc16_reg != 0xFFFF end)
  """
  @spec find_when(t(), atom(), keyword() | function()) :: [map()]
  def find_when(%__MODULE__{} = st, entity, conditions) do
    Query.find_when(st, entity, conditions)
  end

  @doc """
  Find the first tick where conditions were met. Returns nil if never.

      iex> Hw.Simtrace.first(st, :sie, rx_state: 2)
      %{time_ps: 104, state: %{...}}

      iex> Hw.Simtrace.first(st, :cdc, dev_state: 2)
      %{time_ps: 33_332, state: %{dev_state: 2, ep0_state: 0, ...}}
  """
  @spec first(t(), atom(), keyword() | function()) :: map() | nil
  def first(%__MODULE__{} = st, entity, conditions) do
    Query.first(st, entity, conditions)
  end

  @doc """
  Find ticks where a register's value changed. Useful for spotting
  transitions without knowing when they happen.

      iex> Hw.Simtrace.transitions(st, :sie, :rx_state)
      [
        %{time_ps: 41_666,  from: 0, to: 1},
        %{time_ps: 62_499,  from: 1, to: 2},
        %{time_ps: 83_332,  from: 2, to: 0},
        ...
      ]
  """
  @spec transitions(t(), atom(), atom()) :: [map()]
  def transitions(%__MODULE__{} = st, entity, register) do
    Query.transitions(st, entity, register)
  end

  # ---------------------------------------------------------------------------
  # Diff
  # ---------------------------------------------------------------------------

  @doc """
  Show what changed in an entity's registers between two sim times.

      iex> Hw.Simtrace.diff(st, :sie, 100, 208)
      %{
        rx_state:           {0, 2},
        bit_cnt:            {0, 3},
        crc16_reg:          {0xFFFF, 0xB001},
        token_is_in_reg:    {0, 1},
        token_ep_reg:       {0, 1},
      }

  Unchanged registers are omitted. Pass `:first` / `:last` for the
  start/end of the recording.
  """
  @spec diff(t(), atom(), non_neg_integer() | :first | :last,
                          non_neg_integer() | :first | :last) :: map()
  def diff(%__MODULE__{} = st, entity, from_ps, to_ps) do
    Query.diff(st, entity, from_ps, to_ps)
  end

  # ---------------------------------------------------------------------------
  # Cross-entity queries
  # ---------------------------------------------------------------------------

  @doc """
  Snapshot all traced entities at the same sim time. Useful for seeing
  the joint state of the USB stack at a specific moment.

      iex> Hw.Simtrace.snapshot(st, 104)
      %{
        phy: %{phase: 0, rx_state: 1, tx_state: 0, ...},
        sie: %{rx_state: 2, token_is_in_reg: 1, ...},
        cdc: %{dev_state: 1, ep1_in_busy: 0, ...}
      }
  """
  @spec snapshot(t(), non_neg_integer() | :last) :: %{atom() => map()}
  def snapshot(%__MODULE__{} = st, time_ps) do
    Query.snapshot(st, time_ps)
  end

  @doc """
  Given an event returned by `first/3` or `find_when/3`, show the state of all
  other entities at the same sim time.
  Answers "what was CDC doing when the SIE sent a NAK?"

      iex> nak_tick = Hw.Simtrace.first(st, :sie, ep_in_nak: 1)
      iex> Hw.Simtrace.context(st, :sie, nak_tick)
      %{
        time_ps: 20_833,
        origin:  %{entity: :sie, state: %{ep_in_nak: 1, ...}},
        others:  %{
          phy: %{rx_state: 0, tx_state: 0, ...},
          cdc: %{dev_state: 0, ...}   # ← not configured yet — that's your bug
        }
      }
  """
  @spec context(t(), atom(), map()) :: map()
  def context(%__MODULE__{} = st, entity, %{time_ps: _, state: _} = event) do
    Query.context(st, entity, event)
  end

  # ---------------------------------------------------------------------------
  # Waveform
  # ---------------------------------------------------------------------------

  @doc """
  Print an ASCII waveform for registers of one entity.

      iex> Hw.Simtrace.waveform(st, :sie, [:rx_state, :tx_state, :send_handshake])
      sie  t=0 → t=41_666ps  (48 ticks)

      rx_state      ___/‾‾‾\\___/‾‾‾‾‾‾‾‾\\___
      tx_state      ____________/‾‾‾‾‾‾\\______
      send_handshake __________/‾\\__/‾\\________

  ## Options

    * `:ticks`   — number of ticks to show (default: 64)
    * `:from`    — start time in ps (default: first recorded)
    * `:to`      — end time in ps (default: last recorded)
    * `:width`   — terminal width in chars (default: 80)
  """
  @spec waveform(t(), atom(), [atom()], keyword()) :: :ok
  def waveform(%__MODULE__{} = st, entity, registers, opts \\ []) do
    Waveform.print(st, entity, registers, opts)
  end

  @doc """
  Print waveforms for the full USB stack side by side,
  showing the signals most useful for protocol debugging.

      iex> Hw.Simtrace.usb_waveform(st)
      iex> Hw.Simtrace.usb_waveform(st, ticks: 32, from: 0)
  """
  @spec usb_waveform(t(), keyword()) :: :ok
  def usb_waveform(%__MODULE__{} = st, opts \\ []) do
    Waveform.print_usb(st, opts)
  end
end
