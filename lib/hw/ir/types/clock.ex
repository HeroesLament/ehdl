defmodule Hw.IR.Types.Clock do
  @moduledoc """
  A clock domain.

  Clocks are explicit objects, not implicit strings.
  Edge and reset policy must be declared.

  The `source_location` field is populated by the `clock` macro at
  expansion time and used by `Hw.Analysis` for diagnostics.
  """

  alias Hw.Analysis.Location

  @type edge        :: :posedge | :negedge
  @type reset_style :: :sync | :async | :none
  @type reset_type  :: :sync | :async | nil

  @type t :: %__MODULE__{
    name:            atom(),
    edge:            edge(),
    reset:           reset_type(),
    # New structural type fields
    domain:          atom(),            # clock domain name (defaults to clock name)
    reset_signal:    atom() | nil,      # which signal resets this domain
    reset_style:     reset_style(),     # :sync | :async | :none
    freq_mhz:        float() | nil,
    source_location: Location.t() | nil
  }

  @enforce_keys [:name, :edge]
  defstruct [
    :name, :edge, :domain, :reset_signal,
    reset: nil, reset_style: :sync, freq_mhz: nil, source_location: nil
  ]

  @doc "Create a posedge clock (most common)."
  @spec posedge(atom(), keyword()) :: t()
  def posedge(name, opts \\ []) do
    %__MODULE__{
      name:            name,
      edge:            :posedge,
      reset:           Keyword.get(opts, :reset),
      source_location: Keyword.get(opts, :source_location)
    }
  end

  @doc "Create a negedge clock."
  @spec negedge(atom(), keyword()) :: t()
  def negedge(name, opts \\ []) do
    %__MODULE__{
      name:            name,
      edge:            :negedge,
      reset:           Keyword.get(opts, :reset),
      source_location: Keyword.get(opts, :source_location)
    }
  end
end
