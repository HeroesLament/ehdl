defmodule Hw.Diag.Telemetry do
  @moduledoc """
  IEx-native listener for the FPGA health dashboard streamed over US1 (FTDI).

  `Hw.Diag.HealthReport` on the FPGA emits one fixed, self-documenting ASCII
  line per ~10 ms over the US1 serial port at 9600 8N1, e.g.

      PLL1 RST0 | DNH1 RAWK1 RX1 PKT1 ACC1 TX1 | RX0 TX0 DEV1 EP0 A07 D0 N0 \
      HSK1 REQ1 EPL1 OUT1 STP1 Q=0005 MV1 SF1 C7 EP0 DS1 L0005 CD1 CL0 E0A2 \
      CS0 SH1 HB1 MR2 GD0 DR0 CF0 800 LB00

  This module opens that port, reassembles whole lines, parses each one into a
  flat `%{field_key => integer}` map via `Hw.Diag.HealthFrame` (the shared
  schema — so `RX`/`TX`/`EP` label repeats resolve to distinct keys), and lets
  you consume the stream from IEx without touching `cat`/`stty` by hand:

      iex> Hw.Diag.Telemetry.start()          # opens the default port
      iex> Hw.Diag.Telemetry.watch()          # live pretty-print, Ctrl-C twice to stop
      iex> Hw.Diag.Telemetry.latest()         # last parsed sample as a map
      iex> Hw.Diag.Telemetry.get(:getdesc)    # one field: GET_DESCRIPTOR ever dispatched?
      iex> Hw.Diag.Telemetry.subscribe()      # this pid now receives {:fpga, sample}
      iex> Hw.Diag.Telemetry.wait_until(fn s -> s.getdesc == 1 end)

  ## Design notes

  No serial-port dependency is pulled in — the port is read through an Erlang
  port running the system `cat`, after a one-shot `stty` puts the tty in raw
  9600 8N1. That is exactly the path already proven to drain this FTDI link, so
  behaviour matches the manual `cat` reads but is now structured and
  subscribable. All framing/parsing/pub-sub is pure Elixir.

  Parsing is delegated to `Hw.Diag.HealthFrame`/`Hw.Diag.FrameSchema`, which is
  positional and keyed uniquely per field. Adding a dashboard column means
  updating the HDL template and the `HealthFrame` schema together; this listener
  needs no change.
  """

  use GenServer
  require Logger

  alias Hw.Diag.HealthFrame

  @default_port "/dev/cu.usbserial-D01477"
  @default_baud 9600

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Start the listener (registered under this module's name).

  Options:
    * `:port`  — tty device path (default `#{@default_port}`)
    * `:baud`  — baud rate for the one-shot stty (default `#{@default_baud}`)
    * `:name`  — GenServer name (default `#{inspect(__MODULE__)}`)
    * `:log`   — if true, Logger.debug every parsed sample (default false)
  """
  def start(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.start(__MODULE__, opts, name: name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "Start under a supervisor."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @doc "Stop the listener and close the port."
  def stop(name \\ __MODULE__), do: GenServer.stop(name)

  @doc "The most recently parsed sample as a `%{field => integer}` map, or `nil`."
  def latest(name \\ __MODULE__), do: GenServer.call(name, :latest)

  @doc "One field from the latest sample, e.g. `get(:getdesc)`. `nil` if unseen."
  def get(field, name \\ __MODULE__) when is_atom(field) do
    case latest(name) do
      nil -> nil
      m -> Map.get(m, field)
    end
  end

  @doc "How many complete lines have been parsed since start."
  def count(name \\ __MODULE__), do: GenServer.call(name, :count)

  @doc """
  Command the FPGA to force a USB re-enumeration over US1.

  Sends the `'R'` (0x52) command byte down the US1 host->FPGA line. The FPGA's
  `Hw.ReEnum` controller drops the D+ pullup for ~50 ms (the host sees an unplug)
  and re-arms the whole-design reset, so the host then re-runs a fresh
  enumeration on a just-reset device — all sticky diagnostic gauges clear to 0,
  making the next attempt observable from scratch via `watch/0`/`wait_until/2`.

  Works whether or not the listener GenServer is running: it writes directly to
  the tty. Pass `:name` (a running listener) to reuse its configured port, or
  `:port` to target a device path explicitly.

      iex> Hw.Diag.Telemetry.reset()          # uses the running listener's port
      iex> Hw.Diag.Telemetry.reset(port: "/dev/cu.usbserial-XXXX")
  """
  def reset(opts \\ []), do: send_cmd(?R, opts)

  @doc """
  Send a single raw command byte down US1 to the FPGA. `byte` is an integer
  0..255 (e.g. `?R`). See `reset/1` for the port-selection options.
  """
  def send_cmd(byte, opts \\ []) when is_integer(byte) and byte in 0..255 do
    port_path = resolve_port(opts)

    # Ensure the tty is in raw 9600 8N1 before writing (idempotent; the listener
    # sets the same mode, but reset/1 may be called with no listener running).
    _ =
      System.cmd("stty", ["-f", port_path, "9600", "clocal", "cread", "raw"],
        stderr_to_stdout: true
      )

    case File.open(port_path, [:write, :binary, :raw]) do
      {:ok, io} ->
        result = IO.binwrite(io, <<byte>>)
        File.close(io)
        result

      {:error, reason} ->
        {:error, {:open_failed, reason}}
    end
  end

  # Determine the tty path: explicit :port wins; else ask a running listener for
  # its configured port; else fall back to the default.
  defp resolve_port(opts) do
    cond do
      p = Keyword.get(opts, :port) ->
        p

      true ->
        name = Keyword.get(opts, :name, __MODULE__)

        case GenServer.whereis(name) do
          nil -> @default_port
          _pid -> GenServer.call(name, :port_path)
        end
    end
  end

  @doc """
  Subscribe the calling process to the telemetry stream. Each new parsed sample
  is delivered as `{:fpga, sample_map}`. Returns `:ok`.
  """
  def subscribe(name \\ __MODULE__), do: GenServer.call(name, {:subscribe, self()})

  @doc "Stop receiving `{:fpga, _}` messages."
  def unsubscribe(name \\ __MODULE__), do: GenServer.call(name, {:unsubscribe, self()})

  @doc """
  Block until `fun.(sample)` returns truthy for a freshly arrived sample, then
  return `{:ok, sample}`. Times out (default 15 s) returning `{:error, :timeout}`.
  Great for scripted bring-up: `wait_until(fn s -> s.dev_state == 1 end)`.
  """
  def wait_until(fun, opts \\ [], name \\ __MODULE__) when is_function(fun, 1) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    :ok = subscribe(name)

    result =
      case latest(name) do
        m when is_map(m) ->
          if fun.(m), do: {:ok, m}, else: wait_loop(fun, timeout)

        _ ->
          wait_loop(fun, timeout)
      end

    unsubscribe(name)
    result
  end

  defp wait_loop(fun, timeout) do
    receive do
      {:fpga, sample} ->
        if fun.(sample), do: {:ok, sample}, else: wait_loop(fun, timeout)
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Oracle logging: capture a timestamped window of samples.

  Records up to `:count` samples (default 30) or until `:timeout` ms (default
  8000), whichever first, returning `[{ms_since_start, sample}]`. Unlike
  `latest/0` this preserves the SEQUENCE of frames, so a transient transition (a
  reset dip, a gauge flipping for one frame) is visible after the fact.
  """
  def record(opts \\ [], name \\ __MODULE__) do
    count = Keyword.get(opts, :count, 30)
    timeout = Keyword.get(opts, :timeout, 8_000)
    :ok = subscribe(name)
    t0 = System.monotonic_time(:millisecond)
    trace = record_loop(count, t0, timeout, [])
    unsubscribe(name)
    trace
  end

  defp record_loop(0, _t0, _timeout, acc), do: Enum.reverse(acc)

  defp record_loop(count, t0, timeout, acc) do
    remaining = timeout - (System.monotonic_time(:millisecond) - t0)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:fpga, s} ->
          ts = System.monotonic_time(:millisecond) - t0
          record_loop(count - 1, t0, timeout, [{ts, s} | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  @doc """
  Oracle harness: run `trigger_fun`, then capture the window of samples that
  follows so you can see how the device reacts. Drains pending frames first so
  the trace starts at the trigger. Returns `[{ms, sample}]` (see `record/2`).

      iex> Hw.Diag.Telemetry.trace_event(fn -> Hw.Diag.Telemetry.reset() end)
  """
  def trace_event(trigger_fun, opts \\ [], name \\ __MODULE__) when is_function(trigger_fun, 0) do
    :ok = subscribe(name)
    drain_mailbox()
    trigger_fun.()
    t0 = System.monotonic_time(:millisecond)
    count = Keyword.get(opts, :count, 30)
    timeout = Keyword.get(opts, :timeout, 8_000)
    trace = record_loop(count, t0, timeout, [])
    unsubscribe(name)
    trace
  end

  defp drain_mailbox do
    receive do
      {:fpga, _} -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  @doc """
  Pretty-print a trace from `record/2`/`trace_event/3`, one row per sample,
  showing only the fields that CHANGE across the trace (plus the given `keys`).
  Great for spotting exactly which frame a transition happens on.

      iex> t = Hw.Diag.Telemetry.trace_event(fn -> Hw.Diag.Telemetry.reset() end)
      iex> Hw.Diag.Telemetry.print_trace(t, [:rst, :dev_state, :reenum_active, :rst_arm_low])
  """
  def print_trace(trace, keys \\ []) when is_list(trace) do
    samples = Enum.map(trace, fn {_t, s} -> s end)

    changing =
      case samples do
        [] -> []
        [first | _] ->
          Map.keys(first)
          |> Enum.filter(fn k ->
            vals = Enum.map(samples, &Map.get(&1, k))
            Enum.uniq(vals) |> length() > 1
          end)
      end

    shown = (keys ++ changing) |> Enum.uniq()

    Enum.each(trace, fn {t, s} ->
      cells = Enum.map(shown, fn k -> "#{k}=#{Map.get(s, k)}" end)
      IO.puts("+#{String.pad_leading(Integer.to_string(t), 5)}ms  " <> Enum.join(cells, " "))
    end)

    IO.puts("[trace] #{length(trace)} samples; changing fields: #{inspect(changing)}")
    trace
  end

  @doc """
  Live pretty-print of the stream in the current shell. Subscribes, prints one
  compact line per sample highlighting the enumeration-critical fields, and
  keeps going until you interrupt (Ctrl-C twice).
  """
  def watch(name \\ __MODULE__) do
    :ok = subscribe(name)
    IO.puts(:stderr, "[telemetry] watching #{inspect(name)} — Ctrl-C twice to stop")
    watch_loop()
  end

  defp watch_loop do
    receive do
      {:fpga, s} ->
        IO.puts(format_sample(s))
        watch_loop()
    end
  end

  @doc "Return a one-line human summary of a sample map."
  def format_sample(s) when is_map(s) do
    f = fn k -> Map.get(s, k, "?") end

    hexn = fn k, w ->
      case Map.get(s, k) do
        nil -> String.duplicate("?", w)
        v -> v |> Integer.to_string(16) |> String.pad_leading(w, "0") |> String.downcase()
      end
    end

    [
      "PLL#{f.(:pll_locked)} RST#{f.(:rst)}",
      "phy[K#{f.(:lat_raw_k)} RX#{f.(:lat_rx_active)} PKT#{f.(:lat_pkt_end)} " <>
        "ACC#{f.(:lat_accept)} TX#{f.(:lat_tx_ran)}]",
      "DEV#{f.(:dev_state)} A#{hexn.(:dev_addr, 2)} EP0=#{f.(:ep0_state)}",
      "Q=#{hexn.(:req, 4)}",
      "enum[MV#{f.(:lat_ep0moved)} GD#{f.(:getdesc)} DR#{f.(:descrun)} " <>
        "CF#{f.(:setcfg)} 80#{f.(:saw_b0_80)} LB#{hexn.(:last_b0, 2)}]"
    ]
    |> Enum.join("  ")
  end

  # ===========================================================================
  # GenServer
  # ===========================================================================

  @impl true
  def init(opts) do
    port_path = Keyword.get(opts, :port, @default_port)
    baud = Keyword.get(opts, :baud, @default_baud)
    log? = Keyword.get(opts, :log, false)

    # One-shot: put the tty into raw 9600 8N1 (clocal cread) before opening.
    _ =
      System.cmd("stty", ["-f", port_path, "#{baud}", "clocal", "cread", "raw"],
        stderr_to_stdout: true
      )

    # Read the byte stream through `cat`, exactly the proven-good path. An Erlang
    # port keeps this dependency-free; :binary + :stream give raw chunks we frame.
    port =
      Port.open({:spawn_executable, cat_path()}, [
        :binary,
        :stream,
        :exit_status,
        {:args, [port_path]}
      ])

    state = %{
      port: port,
      port_path: port_path,
      buf: "",
      latest: nil,
      count: 0,
      subs: MapSet.new(),
      log?: log?
    }

    {:ok, state}
  end

  defp cat_path do
    System.find_executable("cat") || "/bin/cat"
  end

  @impl true
  def handle_call(:latest, _from, state), do: {:reply, state.latest, state}
  def handle_call(:count, _from, state), do: {:reply, state.count, state}
  def handle_call(:port_path, _from, state), do: {:reply, state.port_path, state}

  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, %{state | subs: MapSet.put(state.subs, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subs: MapSet.delete(state.subs, pid)}}
  end

  @impl true
  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    {lines, rest} = split_lines(state.buf <> bytes)
    state = %{state | buf: rest}

    state =
      Enum.reduce(lines, state, fn line, acc ->
        case parse_line(line) do
          {:ok, sample} ->
            if acc.log?, do: Logger.debug("[fpga] " <> format_sample(sample))
            broadcast(acc.subs, sample)
            %{acc | latest: sample, count: acc.count + 1}

          :skip ->
            acc
        end
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[telemetry] reader for #{state.port_path} exited (#{status})")
    {:stop, {:reader_exited, status}, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subs: MapSet.delete(state.subs, pid)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if is_port(port) do
      try do
        Port.close(port)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp broadcast(subs, sample) do
    Enum.each(subs, fn pid -> send(pid, {:fpga, sample}) end)
  end

  # ---------------------------------------------------------------------------
  # Framing + parsing
  # ---------------------------------------------------------------------------

  # Split a binary into complete lines (on \n) plus a trailing remainder. \r is
  # stripped so CRLF frames parse cleanly.
  defp split_lines(bin) do
    parts = String.split(bin, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    lines = Enum.map(complete, &String.replace(&1, "\r", ""))
    {lines, rest}
  end

  @doc """
  Parse one dashboard line into `{:ok, %{field => integer}}`, or `:skip` if the
  line isn't a complete health frame (garbage/partial). Delegates the field
  layout to `Hw.Diag.HealthFrame`. Exposed for testing.
  """
  def parse_line(line) do
    line = String.trim(line)

    # A valid frame starts at the PLL marker. Anything else is noise/partial.
    if String.starts_with?(line, "PLL") do
      case HealthFrame.parse(line) do
        {:ok, sample} -> {:ok, sample}
        :error -> :skip
      end
    else
      :skip
    end
  end
end
