defmodule Hw.Trace.Window do
  @moduledoc """
  A named time span (transaction) within a `Hw.Trace`.

  Modeled on UVM transaction recording (`begin_tr`/`end_tr`): a producer — a
  protocol driver such as `Hw.Sim.USBHost` — brackets its own phases as it
  drives, and each phase becomes a named, queryable, renderable span. A GTKWave
  point marker is the degenerate zero-width case (`to == from`).

  ## Model decisions (see docs/TRACE_WINDOWS.md §7a)

    * **Overlap-allowed, UVM-style.** Spans are keyed by `id` and may interleave;
      `parent` is *advisory* (the innermost span open at `begin_tr` time), not
      enforced. Concurrent phases are fine.
    * **Time-axis truth.** Bounds are stored in picoseconds (`axis: :time`),
      matching the NIF change log / VCD and what a producer naturally has. The
      `window:` query option converts ps → sample index lazily.
  """

  @type bound :: non_neg_integer()

  @type t :: %__MODULE__{
          id: reference(),
          label: atom() | String.t(),
          from: bound(),
          to: bound() | nil,
          axis: :time | :index,
          parent: reference() | nil,
          meta: map()
        }

  @enforce_keys [:id, :label, :from, :axis]
  defstruct id: nil,
            label: nil,
            from: 0,
            to: nil,
            axis: :time,
            parent: nil,
            meta: %{}

  @doc "True if the span has been closed (has an end bound)."
  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{to: to}), do: not is_nil(to)

  @doc "True if the span is a zero-width point marker."
  @spec point?(t()) :: boolean()
  def point?(%__MODULE__{from: f, to: t}), do: t == f

  @doc "Span duration in axis units, or nil if still open."
  @spec duration(t()) :: non_neg_integer() | nil
  def duration(%__MODULE__{from: f, to: t}) when is_integer(t), do: t - f
  def duration(%__MODULE__{}), do: nil

  @doc """
  Resolve a window's bounds to `{from_ps, to_ps}` for the time axis.

  An open span (`to: nil`) resolves its end to `default_to` (typically the
  trace's last recorded time). A point marker resolves `to == from`.
  """
  @spec bounds(t(), non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def bounds(%__MODULE__{from: f, to: nil}, default_to), do: {f, max(f, default_to)}
  def bounds(%__MODULE__{from: f, to: t}, _default_to), do: {f, t}

  # ---------------------------------------------------------------------------
  # Tier 1 constructors — build a window from query results (GTKWave
  # "interval between two markers"). No producer instrumentation needed.
  # ---------------------------------------------------------------------------

  @doc """
  A window spanning from event `a` to event `b`, labeled `label`.

  `a` and `b` are query-result entries (from `find_when`/`transitions`/`timeline`)
  or bare `time_ps` integers. The lower/upper bounds are ordered automatically.

      [a] = find_when(trace, [scope: :sie], rx_state: 2)
      [b] = find_when(trace, [scope: :cdc], dev_state: 1)
      Window.between(a, b, :set_address)
  """
  @spec between(map() | non_neg_integer(), map() | non_neg_integer(), atom() | String.t(), keyword()) :: t()
  def between(a, b, label, opts \\ []) do
    ta = time_of(a)
    tb = time_of(b)
    {from, to} = if ta <= tb, do: {ta, tb}, else: {tb, ta}

    %__MODULE__{
      id: make_ref(),
      label: label,
      from: from,
      to: to,
      axis: :time,
      parent: nil,
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  @doc """
  A window centered on a point event, extending `±pad` ps.

      Window.around(event, :glitch, pad: 500)
  """
  @spec around(map() | non_neg_integer(), atom() | String.t(), keyword()) :: t()
  def around(event, label, opts \\ []) do
    pad = Keyword.get(opts, :pad, 0)
    center = time_of(event)
    from = max(center - pad, 0)

    %__MODULE__{
      id: make_ref(),
      label: label,
      from: from,
      to: center + pad,
      axis: :time,
      parent: nil,
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  # Extract a ps time from a query-result entry or a bare integer.
  defp time_of(%{time_ps: t}), do: t
  defp time_of(t) when is_integer(t), do: t
end
