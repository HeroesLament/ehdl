defmodule Hw.IR.Design do
  @moduledoc """
  Top-level container for a hardware design.

  A Design is a frozen, explicit representation of hardware structure.
  After elaboration, this is the source of truth.

  ## Invariants

  - All signals referenced by ops must exist in `signals`
  - All clocks referenced by ops must exist in `clocks`
  - No signal may have multiple drivers (checked by validation)
  - All state (registers) must reference a clock
  """

  alias Hw.IR.Types.{Signal, Clock, Param, Localparam}
  alias Hw.IR.Ops

  @type t :: %__MODULE__{
    name: atom(),
    params: [Param.t()],
    localparams: [Localparam.t()],
    signals: [Signal.t()],
    clocks: [Clock.t()],
    ops: [Ops.op()]
  }

  @enforce_keys [:name]
  defstruct [
    :name,
    params: [],
    localparams: [],
    signals: [],
    clocks: [],
    ops: []
  ]

  @doc """
  Create a new design with the given name.
  """
  def new(name) when is_atom(name) do
    %__MODULE__{name: name}
  end

  @doc """
  Add a parameter to the design.
  """
  def add_param(%__MODULE__{} = design, %Param{} = param) do
    %{design | params: [param | design.params]}
  end

  @doc """
  Add a localparam to the design.
  """
  def add_localparam(%__MODULE__{} = design, %Localparam{} = localparam) do
    %{design | localparams: [localparam | design.localparams]}
  end

  @doc """
  Add a clock domain to the design.
  """
  def add_clock(%__MODULE__{} = design, %Clock{} = clock) do
    %{design | clocks: [clock | design.clocks]}
  end

  @doc """
  Add a signal to the design.
  """
  def add_signal(%__MODULE__{} = design, %Signal{} = signal) do
    %{design | signals: [signal | design.signals]}
  end

  @doc """
  Add an operation to the design.
  """
  def add_op(%__MODULE__{} = design, op) do
    %{design | ops: [op | design.ops]}
  end

  @doc """
  Get all input signals.
  """
  def inputs(%__MODULE__{signals: signals}) do
    Enum.filter(signals, &(&1.direction == :input))
  end

  @doc """
  Get all output signals.
  """
  def outputs(%__MODULE__{signals: signals}) do
    Enum.filter(signals, &(&1.direction == :output))
  end

  @doc """
  Get all internal signals.
  """
  def internals(%__MODULE__{signals: signals}) do
    Enum.filter(signals, &(&1.direction == :internal))
  end

  @doc """
  Get all bidirectional (inout) signals.
  """
  def inouts(%__MODULE__{signals: signals}) do
    Enum.filter(signals, &(&1.direction == :inout))
  end

  @doc """
  Finalize the design (reverse accumulated lists for correct order).
  """
  def finalize(%__MODULE__{} = design) do
    %{design |
      params: Enum.reverse(design.params),
      localparams: Enum.reverse(design.localparams),
      signals: Enum.reverse(design.signals),
      clocks: Enum.reverse(design.clocks),
      ops: Enum.reverse(design.ops)
    }
  end
end
