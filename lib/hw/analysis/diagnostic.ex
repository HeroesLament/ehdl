defmodule Hw.Analysis.Diagnostic do
  @moduledoc """
  A structured hardware analysis diagnostic.

  Diagnostics are the output of `Hw.Analysis.run/1`. They are pure
  data — no formatting, no IO. Formatting is handled by
  `Hw.Analysis.Formatter` (CLI) and `Hw.LSP.Server` (LSP protocol).

  The `related` field carries secondary source locations — used to show
  both sides of a mismatch, e.g. "provider declared here, consumer
  declared here". This maps directly to the LSP `relatedInformation`
  field in `textDocument/publishDiagnostics`.

  ## Diagnostic Codes

  Each diagnostic has a machine-readable `code` atom. This allows:
  - Programmatic filtering (suppress specific checks)
  - LSP quick-fix actions keyed by code
  - Stable references in documentation

  Current codes:
    :width_mismatch          — signal widths differ across a connection
    :direction_mismatch      — signal direction incompatible with role
    :missing_signal          — interface signal absent from component
    :unresolved_param        — {:param, name} ref has no binding
    :param_constraint        — param value fails declared constraint
    :unconnected_required    — required interface has no connect
    :unknown_interface       — connect references unknown interface name
    :unknown_instance        — connect references unknown instance name
    :clock_domain_crossing   — signal crosses clock domains unsafely
    :clock_frequency_ratio   — CDC crossing ratio makes Sync2 unreliable
    :unknown_clock_wire      — clock port connected to undeclared clock wire
    :mixed_clock_instance    — non-CDC instance has multiple clock connections
    :multiple_drivers        — wire driven by more than one instance
    :undriven_output         — output port has no driver
    :unconnected_input       — input port left floating in port map
    :unconnected_reset       — instance reset port not connected
  """

  alias Hw.Analysis.Location

  @type severity :: :error | :warning | :hint | :info

  @type code ::
    :width_mismatch
    | :direction_mismatch
    | :missing_signal
    | :unresolved_param
    | :param_constraint
    | :unconnected_required
    | :unknown_interface
    | :unknown_instance
    | :clock_domain_crossing
    | :clock_frequency_ratio
    | :unknown_clock_wire
    | :mixed_clock_instance
    | :multiple_drivers
    | :undriven_output
    | :unconnected_input
    | :unconnected_reset
    | :latch_inference
    | :combinational_loop
    | :reset_cdc
    | :implicit_state_retention
    | :param_boundary
    | :polarity_mismatch
    | :endian_mismatch
    | :persist_violation

  @type related :: %{
    location: Location.t(),
    message:  String.t()
  }

  @type t :: %__MODULE__{
    severity: severity(),
    code:     code(),
    message:  String.t(),
    location: Location.t(),
    # Structured context for rich display — content is code-specific.
    # e.g. for :width_mismatch:
    #   %{signal: :pkt_done, expected: 1, got: 8,
    #     provider: Location.t(), consumer: Location.t()}
    context:  map(),
    # Secondary locations — "other side of mismatch declared here" etc.
    related:  [related()]
  }

  @enforce_keys [:severity, :code, :message, :location]
  defstruct [:severity, :code, :message, :location, context: %{}, related: []]

  @doc "Construct an error diagnostic."
  @spec error(code(), String.t(), Location.t(), keyword()) :: t()
  def error(code, message, location, opts \\ []) do
    %__MODULE__{
      severity: :error,
      code:     code,
      message:  message,
      location: location,
      context:  Keyword.get(opts, :context, %{}),
      related:  Keyword.get(opts, :related, [])
    }
  end

  @doc "Construct a warning diagnostic."
  @spec warning(code(), String.t(), Location.t(), keyword()) :: t()
  def warning(code, message, location, opts \\ []) do
    %__MODULE__{
      severity: :warning,
      code:     code,
      message:  message,
      location: location,
      context:  Keyword.get(opts, :context, %{}),
      related:  Keyword.get(opts, :related, [])
    }
  end

  @doc "Construct a hint diagnostic."
  @spec hint(code(), String.t(), Location.t(), keyword()) :: t()
  def hint(code, message, location, opts \\ []) do
    %__MODULE__{
      severity: :hint,
      code:     code,
      message:  message,
      location: location,
      context:  Keyword.get(opts, :context, %{}),
      related:  Keyword.get(opts, :related, [])
    }
  end

  @doc """
  Sort diagnostics by file then line, for stable CLI output.
  Errors before warnings before hints before info within the same location.
  """
  @spec sort([t()]) :: [t()]
  def sort(diagnostics) do
    Enum.sort_by(diagnostics, fn d ->
      {d.location.file, d.location.line, severity_order(d.severity)}
    end)
  end

  @doc "True if any diagnostic in the list is an error."
  @spec has_errors?([t()]) :: boolean()
  def has_errors?(diagnostics) do
    Enum.any?(diagnostics, &(&1.severity == :error))
  end

  defp severity_order(:error),   do: 0
  defp severity_order(:warning), do: 1
  defp severity_order(:hint),    do: 2
  defp severity_order(:info),    do: 3
end
