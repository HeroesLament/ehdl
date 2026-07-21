defmodule Hw.Trace do
  @moduledoc """
  A unified, engine-agnostic waveform value.

  `Hw.Trace` is the single time-indexed record that both simulation engines
  feed into: the Rust NIF kernel (via a sparse `{time_ps, sig, old, new}` change
  log) and the live Elixir GenServer engine (via dense per-commit snapshots).
  Above it sit one query layer, one renderer, and one assertion API — none of
  which know which engine produced the data.

  See `docs/TRACE_UNIFICATION.md` for the full architecture.

  ## Internal representation

  A trace holds a flat list of *dense* per-step samples (`samples`, oldest
  first), plus a running `current` state that carries every tracked signal
  forward. This is what lets a *sparse* delta produce a *dense* sample: unmentioned
  signals inherit their prior value from `current`.

  Signals are addressed hierarchically as `{scope_path, leaf}` (see
  `Hw.Trace.Scope`). The flat schedule name (e.g. `:sie_rx_state`) is retained on
  each signal's metadata so adapters can key off either form.

  ## The two folds (the crux)

    * `apply_delta/3`    — ingest a sparse NIF change log. Registers only.
    * `apply_snapshot/3` — ingest a dense `%{signal => value}` map. All signals.

  Both take `time_ps` explicitly: the dense (snapshot) path does not
  self-timestamp — the caller threads simulation time in — so time is a
  parameter to both, unifying the picosecond axis across engines.
  """

  alias Hw.Trace.Scope

  @type addr :: Scope.address()

  @type display_hint ::
          :bit
          | :hex
          | :unsigned
          | :signed
          | {:enum, %{integer() => String.t()}}
          | :default

  @type signal_meta :: %{
          addr: addr(),
          name: atom(),
          width: pos_integer(),
          hint: display_hint(),
          domain: atom() | nil,
          sense: :high | :low,
          init: integer()
        }

  @type sample :: %{
          index: non_neg_integer(),
          time_ps: non_neg_integer(),
          values: %{addr() => integer()}
        }

  @type t :: %__MODULE__{
          signals: %{addr() => signal_meta()},
          by_name: %{atom() => addr()},
          scope_tree: %{atom() => [atom()]},
          samples: [sample()],
          current: %{addr() => integer()},
          clock: atom() | nil,
          index: non_neg_integer(),
          last_time_ps: non_neg_integer(),
          transactions: [Hw.Trace.Window.t()],
          open_spans: [reference()]
        }

  @enforce_keys [:signals]
  defstruct signals: %{},
            by_name: %{},
            scope_tree: %{},
            # samples are stored NEWEST-first internally (prepend, O(1)); callers
            # that need oldest-first use `samples/1`.
            samples: [],
            current: %{},
            clock: nil,
            index: 0,
            last_time_ps: 0,
            # transaction spans (windows), in begin order; overlap-allowed,
            # id-keyed. See Hw.Trace.Window / docs/TRACE_WINDOWS.md.
            transactions: [],
            # ids of spans currently open (innermost last) — for advisory parent.
            open_spans: []

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------

  @doc """
  Build an empty trace over a set of signals.

  `signal_specs` is a list of `{flat_name, meta_fields}` where `meta_fields`
  supplies at least `:width`; `:hint`, `:init`, `:domain`, `:sense` are optional
  and defaulted. Adapters (`Hw.Trace.Adapter.Nif`, `.Live`) build this list from
  a `%Hw.Sim.Schedule{}`; tests can build it directly from fixtures.

  ## Options
    * `:clock` — clock atom whose edges define the index axis.
  """
  @spec new([{atom(), map()}], keyword()) :: t()
  def new(signal_specs, opts \\ []) when is_list(signal_specs) do
    metas =
      Map.new(signal_specs, fn {name, fields} ->
        width = Map.get(fields, :width, 1)
        addr = Map.get(fields, :addr) || Scope.resolve(name)

        meta = %{
          addr: addr,
          name: name,
          width: width,
          hint: Map.get(fields, :hint, default_hint(width)),
          domain: Map.get(fields, :domain, nil),
          sense: Map.get(fields, :sense, :high),
          init: Map.get(fields, :init, 0)
        }

        {addr, meta}
      end)

    by_name = Map.new(metas, fn {addr, m} -> {m.name, addr} end)
    current = Map.new(metas, fn {addr, m} -> {addr, m.init} end)

    %__MODULE__{
      signals: metas,
      by_name: by_name,
      scope_tree: build_scope_tree(metas),
      samples: [],
      current: current,
      clock: Keyword.get(opts, :clock),
      index: 0,
      last_time_ps: 0
    }
  end

  # ---------------------------------------------------------------------------
  # The two folds
  # ---------------------------------------------------------------------------

  @doc """
  Ingest a sparse NIF change log: `[{time_ps, flat_name, old, new}]`.

  Only tracked signals are applied; untracked changes are ignored. Unmentioned
  tracked signals carry forward from `current`. Emits exactly one dense sample.
  `time_ps`, when omitted, is derived from the max timestamp in the batch (the
  NIF stream self-timestamps); pass it explicitly to override.
  """
  @spec apply_delta(t(), [{non_neg_integer(), atom(), integer(), integer()}], non_neg_integer() | nil) :: t()
  def apply_delta(%__MODULE__{} = trace, changes, time_ps \\ nil) when is_list(changes) do
    updated =
      Enum.reduce(changes, trace.current, fn {_t, name, _old, new}, acc ->
        case Map.get(trace.by_name, name) do
          nil -> acc
          addr -> Map.put(acc, addr, new)
        end
      end)

    t =
      time_ps ||
        (changes |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> trace.last_time_ps end))

    push_sample(trace, updated, t)
  end

  @doc """
  Ingest a dense snapshot: `%{flat_name => value}` at an explicit `time_ps`.

  Only tracked keys are taken; the rest of the tracked state carries forward.
  Used by the Backend/Live paths, where combinational signals (absent from the
  sparse change log) are captured. `time_ps` is REQUIRED — the snapshot path does
  not self-timestamp.
  """
  @spec apply_snapshot(t(), %{atom() => integer()}, non_neg_integer()) :: t()
  def apply_snapshot(%__MODULE__{} = trace, snapshot, time_ps) when is_map(snapshot) do
    updated =
      Enum.reduce(snapshot, trace.current, fn {name, val}, acc ->
        case Map.get(trace.by_name, name) do
          nil -> acc
          addr -> Map.put(acc, addr, val)
        end
      end)

    push_sample(trace, updated, time_ps)
  end

  defp push_sample(%__MODULE__{} = trace, values, time_ps) do
    sample = %{index: trace.index, time_ps: time_ps, values: values}

    %{
      trace
      | current: values,
        # prepend (newest-first) — O(1) vs the old O(n) `samples ++ [x]`
        samples: [sample | trace.samples],
        index: trace.index + 1,
        last_time_ps: time_ps
    }
  end

  # ---------------------------------------------------------------------------
  # Transaction recording (UVM begin_tr / end_tr / mark)
  # ---------------------------------------------------------------------------

  alias Hw.Trace.Window

  @doc """
  Open a transaction span named `label` at `time_ps`.

  Overlap-allowed: the new span's `parent` is set to the innermost currently-open
  span (advisory), and its `id` is pushed onto the open stack. Close it with
  `end_tr/3` (by label — the most-recently-opened span with that label closes).

      trace = Trace.begin_tr(trace, :setup_get_descriptor, t)
  """
  @spec begin_tr(t(), atom() | String.t(), non_neg_integer(), map()) :: t()
  def begin_tr(%__MODULE__{} = trace, label, time_ps, meta \\ %{}) do
    id = make_ref()
    parent = List.last(trace.open_spans)

    span = %Window{
      id: id,
      label: label,
      from: time_ps,
      to: nil,
      axis: :time,
      parent: parent,
      meta: meta
    }

    %{
      trace
      | transactions: trace.transactions ++ [span],
        open_spans: trace.open_spans ++ [id]
    }
  end

  @doc """
  Close the most-recently-opened open span named `label` at `time_ps`.

  If no open span carries that label, the trace is returned unchanged (a lenient
  policy — a lint pass can flag unmatched ends). Removes the span's id from the
  open stack regardless of nesting position (overlap-allowed).
  """
  @spec end_tr(t(), atom() | String.t(), non_neg_integer()) :: t()
  def end_tr(%__MODULE__{} = trace, label, time_ps) do
    # find the newest still-open span with this label
    target =
      trace.transactions
      |> Enum.reverse()
      |> Enum.find(fn s -> s.label == label and is_nil(s.to) and s.id in trace.open_spans end)

    case target do
      nil ->
        trace

      span ->
        closed = %{span | to: time_ps}

        %{
          trace
          | transactions: replace_span(trace.transactions, closed),
            open_spans: List.delete(trace.open_spans, span.id)
        }
    end
  end

  @doc """
  Record a zero-width point marker named `label` at `time_ps` (GTKWave-style).
  """
  @spec mark(t(), atom() | String.t(), non_neg_integer(), map()) :: t()
  def mark(%__MODULE__{} = trace, label, time_ps, meta \\ %{}) do
    span = %Window{
      id: make_ref(),
      label: label,
      from: time_ps,
      to: time_ps,
      axis: :time,
      parent: List.last(trace.open_spans),
      meta: meta
    }

    %{trace | transactions: trace.transactions ++ [span]}
  end

  @doc "All recorded transaction spans, in begin order."
  @spec transactions(t()) :: [Window.t()]
  def transactions(%__MODULE__{transactions: txs}), do: txs

  @doc """
  Look up spans by label. Returns all matching spans (a label may recur —
  e.g. `:token` appears in every SETUP). Newest-open-first is not guaranteed;
  they are returned in begin order.
  """
  @spec windows(t(), atom() | String.t()) :: [Window.t()]
  def windows(%__MODULE__{transactions: txs}, label) do
    Enum.filter(txs, &(&1.label == label))
  end

  @doc "The single span for a label, or nil. Raises if the label is ambiguous."
  @spec window(t(), atom() | String.t()) :: Window.t() | nil
  def window(%__MODULE__{} = trace, label) do
    case windows(trace, label) do
      [] -> nil
      [one] -> one
      many -> raise ArgumentError, "window label #{inspect(label)} is ambiguous (#{length(many)} spans); use windows/2"
    end
  end

  defp replace_span(txs, %Window{id: id} = updated) do
    Enum.map(txs, fn s -> if s.id == id, do: updated, else: s end)
  end

  # ---------------------------------------------------------------------------
  # Readback
  # ---------------------------------------------------------------------------

  @doc "All samples, oldest-first."
  @spec samples(t()) :: [sample()]
  def samples(%__MODULE__{samples: s}), do: Enum.reverse(s)

  @doc "Number of recorded samples."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{index: i}), do: i

  @doc """
  Resolve any signal reference (flat atom, dotted string/atom, or an
  `{scope, leaf}` address) to a canonical address in this trace.
  Returns `nil` if the signal isn't tracked.
  """
  @spec address(t(), atom() | String.t() | addr()) :: addr() | nil
  def address(%__MODULE__{by_name: by_name} = trace, ref) do
    cond do
      is_tuple(ref) -> if Map.has_key?(trace.signals, ref), do: ref, else: nil
      is_atom(ref) and Map.has_key?(by_name, ref) -> by_name[ref]
      true -> match_parsed(trace, Scope.parse(ref))
    end
  end

  defp match_parsed(trace, {_scope, _leaf} = addr) do
    if Map.has_key?(trace.signals, addr), do: addr, else: nil
  end

  @doc """
  Value of a signal at a given sample index. Returns the signal's init value if
  the index precedes any recorded sample, or `nil` if the signal is untracked.
  """
  @spec at(t(), atom() | String.t() | addr(), non_neg_integer()) :: integer() | nil
  def at(%__MODULE__{} = trace, ref, index) do
    case address(trace, ref) do
      nil ->
        nil

      addr ->
        case Enum.find(trace.samples, &(&1.index == index)) do
          nil -> get_in(trace.signals, [addr, :init])
          sample -> Map.get(sample.values, addr, trace.signals[addr].init)
        end
    end
  end

  @doc "Full ordered value series for a signal (oldest-first)."
  @spec values(t(), atom() | String.t() | addr()) :: [integer()]
  def values(%__MODULE__{} = trace, ref) do
    case address(trace, ref) do
      nil ->
        []

      addr ->
        init = trace.signals[addr].init
        trace |> samples() |> Enum.map(&Map.get(&1.values, addr, init))
    end
  end

  @doc "Signal metadata for a reference, or nil."
  @spec meta(t(), atom() | String.t() | addr()) :: signal_meta() | nil
  def meta(%__MODULE__{} = trace, ref) do
    case address(trace, ref) do
      nil -> nil
      addr -> trace.signals[addr]
    end
  end

  @doc "All tracked signal addresses, grouped by scope (for tree rendering/browsing)."
  @spec scope_tree(t()) :: %{atom() => [atom()]}
  def scope_tree(%__MODULE__{scope_tree: tree}), do: tree

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_scope_tree(metas) do
    metas
    |> Map.values()
    |> Enum.group_by(
      fn %{addr: {scope, _leaf}} -> List.first(scope) end,
      fn %{addr: {_scope, leaf}} -> leaf end
    )
    |> Map.new(fn {scope, leaves} -> {scope, Enum.sort(leaves)} end)
  end

  defp default_hint(1), do: :bit
  defp default_hint(w) when w <= 8, do: :unsigned
  defp default_hint(_), do: :hex
end
