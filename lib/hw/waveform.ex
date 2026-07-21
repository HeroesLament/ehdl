defmodule Hw.Waveform do
  @moduledoc """
  First-class waveform primitive for EHDL.

  A `Waveform` is a queryable, renderable, assertable record of signal
  history produced during simulation. It is the primary human-facing
  artifact for understanding circuit behaviour over time.

  ## Mental model

  A waveform is not a file format and not a side-effect of simulation.
  It is a value — a time-indexed history of named signal observations —
  that you build incrementally by feeding it the change log from each
  `Hw.Sim.Nif.tick/3` call, then query, render, or assert against.

      # Attach a waveform to an automaton
      {auto, waves} = Hw.Waveform.attach(auto, schedule,
        signals: :ports,
        display: [cdc_rx_state: {:enum, %{0 => "idle", 1 => "data", 2 => "done"}}]
      )

      # Tick the NIF and feed changes to the waveform
      {:ok, auto, changes} = Hw.Sim.Nif.tick(auto, :clk_48, 1000)
      waves = Hw.Waveform.record(waves, changes)

      # Inspect
      IO.puts Hw.Waveform.render(waves)
      Hw.Waveform.assert_stable(waves, :cdc_rx_valid, during: 10..20)

  ## Signal selection

  Pass `signals:` to `attach/3` to control what is recorded:

    - `:ports`   — top-level inputs and outputs only  (default)
    - `:all`     — every signal in the schedule
    - `[atom()]` — explicit list of signal name atoms

  ## Display hints

  Pass `display:` to `attach/3` to control how values render:

    - `{signal, :bit}`            — force 1-bit rendering
    - `{signal, :hex}`            — hexadecimal
    - `{signal, :unsigned}`       — decimal unsigned
    - `{signal, :signed}`         — decimal signed
    - `{signal, {:enum, map}}`    — integer → label map
    - `{signal, :default}`        — pick from signal metadata

  ## Cycle indexing

  Samples are keyed by cycle number starting from 0 at the first
  recorded change. Cycle N = the state after the Nth completed clock edge
  of the tracked clock. `at/2` and `slice/2` use cycle numbers.

  ## ExUnit integration

  Use `assert_waveform/2` for expect-style diffable tests:

      assert_waveform waves, \"\"\"
      cycle     0 1 2
      clr       0 0 0
      incr      0 1 1
      count     0 1 2
      \"\"\"

  See `Hw.Waveform.ExUnit` for the full assertion API.
  """

  import Bitwise

  alias Hw.Sim.Schedule

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type signal_name :: atom()
  @type cycle       :: non_neg_integer()
  @type time_ps     :: non_neg_integer()

  @type display_hint ::
    :bit
    | :hex
    | :unsigned
    | :signed
    | {:enum, %{integer() => String.t()}}
    | :default

  @type signal_meta :: %{
    name:    signal_name(),
    width:   pos_integer(),
    hint:    display_hint(),
    domain:  atom() | nil,
    sense:   :high | :low,
    init:    integer()
  }

  @type sample :: %{
    cycle:   cycle(),
    time_ps: time_ps(),
    values:  %{signal_name() => integer()}
  }

  @type t :: %__MODULE__{
    signals:      %{signal_name() => signal_meta()},
    samples:      [sample()],           # oldest first
    current:      %{signal_name() => integer()},  # live state after last record
    clock:        atom() | nil,         # which clock is being tracked
    cycle_count:  non_neg_integer(),
    last_time_ps: time_ps()
  }

  @enforce_keys [:signals]
  defstruct [
    :clock,
    signals:      %{},
    samples:      [],
    current:      %{},
    cycle_count:  0,
    last_time_ps: 0
  ]

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  @doc """
  Create a waveform recorder from a compiled schedule.

  The returned `Hw.Waveform` is ready to receive change logs via `record/2`.

  ## Options

    * `:signals`  — which signals to record. `:ports` (default), `:all`,
                    or an explicit `[atom()]` list.
    * `:clock`    — which clock's edges define cycles. Defaults to the first
                    clock in the schedule.
    * `:display`  — keyword list of `{signal_atom, display_hint()}` overrides.

  ## Examples

      waves = Hw.Waveform.new(schedule)
      waves = Hw.Waveform.new(schedule, signals: :all)
      waves = Hw.Waveform.new(schedule, signals: [:dp, :dn, :rx_state],
                display: [rx_state: {:enum, %{0 => "idle", 1 => "sync"}}])
  """
  @spec new(Schedule.t(), keyword()) :: t()
  def new(%Schedule{} = schedule, opts \\ []) do
    signal_filter = Keyword.get(opts, :signals, :ports)
    display_opts  = Keyword.get(opts, :display, [])
    clock         = Keyword.get(opts, :clock, first_clock(schedule))

    selected = select_signals(schedule, signal_filter)

    signal_metas =
      Map.new(selected, fn name ->
        width  = Map.get(schedule.signal_widths, name, 1)
        hint   = Keyword.get(display_opts, name, default_hint(width))
        init   = Map.get(Map.get(schedule, :signal_inits, %{}), name, 0)
        domain = domain_of(schedule, name)
        sense  = :high  # could be enriched from design signals if passed through

        meta = %{
          name:   name,
          width:  width,
          hint:   hint,
          domain: domain,
          sense:  sense,
          init:   init
        }
        {name, meta}
      end)

    initial_values = Map.new(signal_metas, fn {name, meta} -> {name, meta.init} end)

    %__MODULE__{
      signals:      signal_metas,
      samples:      [],
      current:      initial_values,
      clock:        clock,
      cycle_count:  0,
      last_time_ps: 0
    }
  end

  @doc """
  Attach a waveform recorder to a compiled NIF automaton.

  Convenience wrapper that builds a `Waveform` from the schedule and
  returns `{automaton, waves}` so you can pipe the result.

      {:ok, auto} = Hw.Sim.Nif.compile(compiled)
      {auto, waves} = Hw.Waveform.attach(auto, schedule, signals: :ports)
  """
  @spec attach(term(), Schedule.t(), keyword()) :: {term(), t()}
  def attach(automaton, %Schedule{} = schedule, opts \\ []) do
    waves = new(schedule, opts)
    {automaton, waves}
  end

  # ---------------------------------------------------------------------------
  # Recording
  # ---------------------------------------------------------------------------

  @doc """
  Feed a NIF change log into the waveform, advancing by one cycle.

  `changes` is the list of `{time_ps, signal_atom, old_val, new_val}`
  tuples returned by `Hw.Sim.Nif.tick/3`.

  Each call to `record/2` represents one or more completed clock edges.
  The waveform snaps the resulting signal state as a single sample
  after all changes are applied, then increments the cycle counter.

  For multi-edge ticks (n > 1), call `record/2` once per tick batch.
  If you need per-edge resolution, tick with n=1 in a loop.

      {:ok, auto, changes} = Hw.Sim.Nif.tick(auto, :clk_48, 1)
      waves = Hw.Waveform.record(waves, changes)
  """
  @spec record(t(), [{time_ps(), atom(), integer(), integer()}]) :: t()
  def record(%__MODULE__{} = waves, changes) when is_list(changes) do
    # Apply changes to current state (only tracked signals)
    updated =
      Enum.reduce(changes, waves.current, fn {_t, sig, _old, new}, acc ->
        if Map.has_key?(acc, sig) do
          Map.put(acc, sig, new)
        else
          acc
        end
      end)

    # Determine time from last change in this batch, or keep current
    last_t =
      changes
      |> Enum.map(&elem(&1, 0))
      |> Enum.max(fn -> waves.last_time_ps end)

    sample = %{
      cycle:   waves.cycle_count,
      time_ps: last_t,
      values:  updated
    }

    %{waves |
      current:      updated,
      samples:      waves.samples ++ [sample],
      cycle_count:  waves.cycle_count + 1,
      last_time_ps: last_t
    }
  end

  @doc """
  Record a raw snapshot of signal values as a single cycle.

  Use this when driving from the Elixir GenServer-based sim instead of
  the NIF, or when you want to inject a manually constructed sample.

      snapshot = Hw.Sim.State.snapshot(sim_id)
      waves = Hw.Waveform.record_snapshot(waves, snapshot, time_ps)
  """
  @spec record_snapshot(t(), %{atom() => integer()}, time_ps()) :: t()
  def record_snapshot(%__MODULE__{} = waves, snapshot, time_ps \\ 0) do
    filtered = Map.take(snapshot, Map.keys(waves.signals))
    merged   = Map.merge(waves.current, filtered)

    sample = %{
      cycle:   waves.cycle_count,
      time_ps: time_ps,
      values:  merged
    }

    %{waves |
      current:      merged,
      samples:      waves.samples ++ [sample],
      cycle_count:  waves.cycle_count + 1,
      last_time_ps: time_ps
    }
  end

  # ---------------------------------------------------------------------------
  # Query
  # ---------------------------------------------------------------------------

  @doc """
  Return the value of a signal at a given cycle.

  Returns the signal's init value if the cycle precedes any recorded sample.

      val = Hw.Waveform.at(waves, :cdc_rx_valid, 5)
  """
  @spec at(t(), signal_name(), cycle()) :: integer() | nil
  def at(%__MODULE__{} = waves, signal, cycle) do
    sample = Enum.find(waves.samples, &(&1.cycle == cycle))
    case sample do
      nil -> get_in(waves.signals, [signal, :init])
      s   -> Map.get(s.values, signal)
    end
  end

  @doc """
  Return all values of a signal across all recorded cycles, in order.

      values = Hw.Waveform.values(waves, :count)
      #=> [0, 1, 2, 3, ...]
  """
  @spec values(t(), signal_name()) :: [integer()]
  def values(%__MODULE__{} = waves, signal) do
    Enum.map(waves.samples, fn s -> Map.get(s.values, signal, 0) end)
  end

  @doc """
  Return a sub-waveform covering only cycles in the given range.

      sub = Hw.Waveform.slice(waves, 10..20)
  """
  @spec slice(t(), Range.t()) :: t()
  def slice(%__MODULE__{} = waves, first..last//_) do
    kept = Enum.filter(waves.samples, fn s -> s.cycle >= first and s.cycle <= last end)
    %{waves | samples: kept}
  end

  @doc """
  Return recorded signals and their last known values as a flat map.

      Hw.Waveform.current(waves)
      #=> %{dp: 1, dn: 0, rx_state: 2}
  """
  @spec current(t()) :: %{signal_name() => integer()}
  def current(%__MODULE__{current: c}), do: c

  @doc "Number of recorded cycles."
  @spec cycle_count(t()) :: non_neg_integer()
  def cycle_count(%__MODULE__{cycle_count: n}), do: n

  # ---------------------------------------------------------------------------
  # Assertions
  # ---------------------------------------------------------------------------

  @doc """
  Assert that a signal holds a constant value throughout a cycle range.

      Hw.Waveform.assert_stable(waves, :valid, during: 5..10)
      Hw.Waveform.assert_stable(waves, :valid, value: 1, during: 5..10)
  """
  @spec assert_stable(t(), signal_name(), keyword()) :: :ok
  def assert_stable(%__MODULE__{} = waves, signal, opts) do
    range    = Keyword.get(opts, :during, 0..(waves.cycle_count - 1))
    expected = Keyword.get(opts, :value, nil)

    sub  = slice(waves, range)
    vals = values(sub, signal)

    if Enum.empty?(vals), do: raise("""
    Waveform assertion failed: #{signal} has no samples in range #{inspect(range)}
      (#{waves.cycle_count} cycles recorded, range #{inspect(range)} is out of bounds)
    """)

    [head | rest] = vals
    expected = expected || head

    bad = rest
      |> Enum.with_index(range.first + 1)
      |> Enum.find(fn {v, _} -> v != expected end)

    case bad do
      nil ->
        :ok
      {actual, cycle} ->
        raise """
        Waveform assertion failed: #{signal} not stable during #{inspect(range)}
          expected: #{format_value(expected, waves.signals[signal])}
          changed to #{format_value(actual, waves.signals[signal])} at cycle #{cycle}
        """
    end
  end

  @doc """
  Assert that a signal transitions through a sequence of values across
  consecutive cycles, starting at `from:` (default 0).

      Hw.Waveform.assert_sequence(waves, :rx_state, [0, 1, 2, 1, 0])
      Hw.Waveform.assert_sequence(waves, :rx_state, [0, 1, 2], from: 5)
  """
  @spec assert_sequence(t(), signal_name(), [integer()], keyword()) :: :ok
  def assert_sequence(%__MODULE__{} = waves, signal, expected_seq, opts \\ []) do
    start = Keyword.get(opts, :from, 0)
    last  = start + length(expected_seq) - 1
    sub   = slice(waves, start..last)
    actual_seq = values(sub, signal)

    if actual_seq != expected_seq do
      meta = waves.signals[signal]
      actual_str   = Enum.map_join(actual_seq,   " ", &format_value(&1, meta))
      expected_str = Enum.map_join(expected_seq, " ", &format_value(&1, meta))
      raise """
      Waveform assertion failed: #{signal} sequence mismatch (cycles #{start}..#{last})
        expected: #{expected_str}
        actual:   #{actual_str}
      """
    end
    :ok
  end

  @doc """
  Assert that a signal reaches a given value within a cycle range.

      Hw.Waveform.assert_reaches(waves, :cdc_rx_valid, 1, by: 20)
  """
  @spec assert_reaches(t(), signal_name(), integer(), keyword()) :: :ok
  def assert_reaches(%__MODULE__{} = waves, signal, target, opts \\ []) do
    by = Keyword.get(opts, :by, waves.cycle_count - 1)
    sub = slice(waves, 0..by)

    found = Enum.any?(sub.samples, fn s -> Map.get(s.values, signal) == target end)

    unless found do
      meta = waves.signals[signal]
      raise """
      Waveform assertion failed: #{signal} never reached #{format_value(target, meta)} by cycle #{by}
        final value: #{format_value(Map.get(waves.current, signal, 0), meta)}
      """
    end
    :ok
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  @label_col 20

  @doc """
  Render the waveform as an ASCII string.

  ## Options

    * `:signals`   — list of signal atoms to render (default: all tracked)
    * `:from`      — first cycle to render (default: 0)
    * `:to`        — last cycle to render (default: last recorded)
    * `:cols`      — total display columns (default: 80)
    * `:group_by`  — `:domain` to group signals by clock domain
    * `:format`    — `:compact` (default) or `:table`

  ## Example output

      cycle          0 1 2 3 4 5
      [core]
        rst_n        ‾ ‾ ‾ ‾ ‾ ‾
        incr         _ ‾ ‾ ‾ ‾ ‾
        count        0─1─2─3─4─5

  """
  @spec render(t(), keyword()) :: String.t()
  def render(%__MODULE__{} = waves, opts \\ []) do
    sig_filter = Keyword.get(opts, :signals, Map.keys(waves.signals) |> Enum.sort())
    from       = Keyword.get(opts, :from, 0)
    to         = Keyword.get(opts, :to, max(waves.cycle_count - 1, 0))
    cols       = Keyword.get(opts, :cols, 80)
    group_by   = Keyword.get(opts, :group_by, nil)

    n_cols = cols - @label_col

    samples_in_range =
      waves.samples
      |> Enum.filter(fn s -> s.cycle >= from and s.cycle <= to end)

    if Enum.empty?(samples_in_range) do
      "(no waveform data recorded)\n"
    else
      n_cycles = to - from + 1
      cycle_labels = render_cycle_header(from, to, n_cols)

      sig_rows =
        if group_by == :domain do
          render_grouped(waves, sig_filter, samples_in_range, n_cycles, n_cols)
        else
          render_flat(waves, sig_filter, samples_in_range, n_cycles, n_cols)
        end

      [cycle_labels | sig_rows]
      |> Enum.join("\n")
      |> Kernel.<>("\n")
    end
  end

  @doc """
  Render the waveform as a VCD (Value Change Dump) string for GTKWave/Surfer.

  Pass `path:` to write to a file instead of returning a string.

      Hw.Waveform.to_vcd(waves)
      Hw.Waveform.to_vcd(waves, path: "/tmp/trace.vcd")
  """
  @spec to_vcd(t(), keyword()) :: String.t() | :ok
  def to_vcd(%__MODULE__{} = waves, opts \\ []) do
    path = Keyword.get(opts, :path, nil)
    vcd  = build_vcd(waves)

    if path do
      File.write!(path, vcd)
      :ok
    else
      vcd
    end
  end

  # ---------------------------------------------------------------------------
  # Private — signal selection
  # ---------------------------------------------------------------------------

  defp select_signals(%Schedule{} = schedule, :ports) do
    # Ports = signals whose names don't have entity prefixes
    # In EHDL's naming convention, top-level IO signals have no "_" entity prefix
    # Fall back to all signals if no obvious port pattern
    all = Map.keys(schedule.signal_widths)
    ports = Enum.reject(all, fn name ->
      str = Atom.to_string(name)
      # Entity-owned signals look like :phy_rx_state, :sie_tx_state, etc.
      known_prefixes = ["phy_", "sie_", "cdc_", "uart_tx_", "uart_rx_",
                        "rst_sync_", "axi_", "spi_"]
      Enum.any?(known_prefixes, &String.starts_with?(str, &1))
    end)
    if Enum.empty?(ports), do: all, else: Enum.sort(ports)
  end

  defp select_signals(%Schedule{} = schedule, :all) do
    schedule.signal_widths |> Map.keys() |> Enum.sort()
  end

  defp select_signals(%Schedule{}, signals) when is_list(signals) do
    signals
  end

  defp domain_of(%Schedule{entities: entities}, signal_name) do
    str = Atom.to_string(signal_name)
    result = Enum.find(entities, fn {_name, entity} ->
      String.starts_with?(str, Atom.to_string(entity.name) <> "_")
    end)
    case result do
      {_, entity} -> entity.domain
      nil         -> nil
    end
  end

  defp first_clock(%Schedule{clocks: [clk | _]}), do: clk.name
  defp first_clock(_), do: nil

  defp default_hint(1),  do: :bit
  defp default_hint(w) when w <= 8,  do: :unsigned
  defp default_hint(_), do: :hex

  # ---------------------------------------------------------------------------
  # Private — rendering
  # ---------------------------------------------------------------------------

  defp render_cycle_header(from, to, n_cols) do
    label = String.pad_trailing("cycle", @label_col)
    n = to - from + 1

    nums =
      if n <= n_cols do
        # One char per cycle
        from..to
        |> Enum.map_join(" ", fn c ->
          Integer.to_string(rem(c, 10))
        end)
      else
        # Compressed: show every Nth
        step = ceil(n / n_cols)
        from..to//step
        |> Enum.map_join("", fn c -> Integer.to_string(rem(c, 10)) end)
        |> String.slice(0, n_cols)
      end

    label <> nums
  end

  defp render_flat(waves, sig_filter, samples, n_cycles, n_cols) do
    Enum.map(sig_filter, fn name ->
      meta = Map.get(waves.signals, name)
      if meta do
        vals = extract_values(samples, name, meta.init, n_cycles)
        label = String.pad_trailing("  " <> Atom.to_string(name), @label_col)
        label <> render_signal_row(vals, meta, n_cols)
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp render_grouped(waves, sig_filter, samples, n_cycles, n_cols) do
    groups =
      sig_filter
      |> Enum.group_by(fn name ->
        meta = Map.get(waves.signals, name)
        if meta, do: meta.domain, else: nil
      end)

    Enum.flat_map(groups, fn {domain, names} ->
      header = if domain, do: ["[#{domain}]"], else: []
      rows = Enum.map(names, fn name ->
        meta = Map.get(waves.signals, name)
        if meta do
          vals = extract_values(samples, name, meta.init, n_cycles)
          label = String.pad_trailing("  " <> Atom.to_string(name), @label_col)
          label <> render_signal_row(vals, meta, n_cols)
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      header ++ rows
    end)
  end

  defp extract_values(samples, signal, init, _n_cycles) do
    Enum.map(samples, fn s -> Map.get(s.values, signal, init) end)
  end

  defp render_signal_row(values, %{width: 1}, n_cols) do
    cols = sample_to_columns(values, n_cols)
    cols
    |> Enum.with_index()
    |> Enum.map_join("", fn {v, i} ->
      prev = if i > 0, do: Enum.at(cols, i - 1), else: v
      cond do
        prev == 0 and v == 1 -> "/"
        prev == 1 and v == 0 -> "\\"
        v == 1               -> "‾"
        true                 -> "_"
      end
    end)
  end

  defp render_signal_row(values, meta, n_cols) do
    cols = sample_to_columns(values, n_cols)
    runs = Enum.chunk_by(cols, & &1)
      |> Enum.map(fn run -> {hd(run), length(run)} end)

    Enum.flat_map(runs, fn {val, len} ->
      label = format_value(val, meta)
      if len <= String.length(label) + 1 do
        List.duplicate("─", len)
      else
        pad = len - String.length(label)
        [label | List.duplicate("─", pad)]
      end
    end)
    |> IO.iodata_to_binary()
  end

  defp sample_to_columns(values, n_cols) do
    n = length(values)
    cond do
      n == 0 ->
        List.duplicate(0, n_cols)
      n <= n_cols ->
        scale = n_cols / n
        Enum.flat_map(Enum.with_index(values), fn {v, i} ->
          count = round((i + 1) * scale) - round(i * scale)
          List.duplicate(v, max(count, 1))
        end)
        |> Enum.take(n_cols)
      true ->
        Enum.map(0..(n_cols - 1), fn col ->
          idx = round(col * (n - 1) / (n_cols - 1))
          Enum.at(values, idx, 0)
        end)
    end
  end

  defp format_value(val, nil), do: Integer.to_string(val)
  defp format_value(val, %{hint: :bit}),      do: Integer.to_string(band(val, 1))
  defp format_value(val, %{hint: :hex}),      do: "0x" <> Integer.to_string(val, 16)
  defp format_value(val, %{hint: :unsigned}), do: Integer.to_string(val)
  defp format_value(val, %{hint: :signed, width: w}) do
    signed = if bsr(val, w - 1) == 1, do: val - bsl(1, w), else: val
    Integer.to_string(signed)
  end
  defp format_value(val, %{hint: {:enum, map}}) do
    Map.get(map, val, Integer.to_string(val))
  end
  defp format_value(val, _), do: Integer.to_string(val)

  # ---------------------------------------------------------------------------
  # Private — VCD generation
  # ---------------------------------------------------------------------------

  defp build_vcd(%__MODULE__{} = waves) do
    id_map = waves.signals
      |> Map.keys()
      |> Enum.sort()
      |> Enum.with_index()
      |> Map.new(fn {name, i} -> {name, vcd_id(i)} end)

    header = build_vcd_header(waves, id_map)
    body   = build_vcd_body(waves, id_map)

    IO.iodata_to_binary([header, body])
  end

  defp build_vcd_header(waves, id_map) do
    sigs = waves.signals |> Enum.sort_by(fn {k, _} -> k end)
    decls = Enum.map(sigs, fn {name, meta} ->
      id   = id_map[name]
      type = if meta.width == 1, do: "wire", else: "wire"
      "$var #{type} #{meta.width} #{id} #{name} $end\n"
    end)

    inits = Enum.map(sigs, fn {name, meta} ->
      id  = id_map[name]
      val = meta.init
      vcd_value_line(val, meta.width, id)
    end)

    ["$timescale 1ps $end\n",
     "$scope module top $end\n",
     decls,
     "$upscope $end\n",
     "$enddefinitions $end\n",
     "$dumpvars\n",
     inits,
     "$end\n",
     "#0\n"]
  end

  defp build_vcd_body(waves, id_map) do
    # Walk samples in order; emit timestamp + any changed signals
    {lines, _prev} =
      Enum.reduce(waves.samples, {[], %{}}, fn sample, {acc, prev} ->
        ts    = sample.time_ps
        changes =
          Enum.flat_map(sample.values, fn {name, val} ->
            meta = waves.signals[name]
            if Map.get(prev, name) != val and meta do
              id = id_map[name]
              [vcd_value_line(val, meta.width, id)]
            else
              []
            end
          end)

        if Enum.any?(changes) do
          {acc ++ ["##{ts}\n" | changes], Map.merge(prev, sample.values)}
        else
          {acc, prev}
        end
      end)

    lines
  end

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
end
