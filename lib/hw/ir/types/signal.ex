defmodule Hw.IR.Types.Signal do
  @moduledoc """
  A named, typed wire or storage location.

  ## Structural Type Annotations

  Beyond width and direction, signals carry four optional structural
  annotations that the analysis system uses to catch classes of bugs
  that are otherwise invisible to the compiler and synthesizer.

  ### `clock_domain`

  Which clock domain owns this signal. Inferred automatically by the
  elaborator from which `on :clk` block assigns to it. Explicit
  declaration is only needed for top-level ports where the domain is
  not inferable from context. CDC crossings between domains are flagged
  by the `Hw.Analysis.Rules.CDCCrossing` rule.

      wire :rx_data, 8, clock_domain: :usb

  ### `sense`

  The active logic level of the signal. `:high` means the signal is
  asserted when it is 1 (the default for most signals). `:low` means
  the signal is asserted when it is 0 — e.g. active-low resets,
  active-low chip-selects, buttons with pull-ups.

  The `Hw.Analysis.Rules.PolarityMismatch` rule flags uses of
  active-low signals in boolean contexts without explicit inversion,
  and flags direct connections between signals of opposite sense.

      input :btn_pwr_n, 1, sense: :low
      wire  :rst_n,     1, sense: :low

  ### `endian`

  Byte order for signals wider than 8 bits. `:little` means the LSB
  is at the lowest byte address (Intel convention). `:big` means the
  MSB is at the lowest byte address (network / USB convention).
  Single-byte signals ignore this field.

  The `Hw.Analysis.Rules.EndianMismatch` rule flags direct connections
  between signals of differing endianness without an explicit swap.

      wire :wLength,  16, endian: :little   # USB descriptor field
      wire :eth_type, 16, endian: :big      # Ethernet EtherType

  ### `persist`

  Reset scope — whether the register's value is meaningful across a
  soft reset (bus reset, watchdog, etc.) or only across a full
  power-on reset.

  - `:full` (default) — cleared by any reset, including soft resets
  - `:power_on_only`  — only cleared at power-on; survives soft resets

  The `Hw.Analysis.Rules.PersistenceMismatch` rule flags signals
  marked `:power_on_only` that are connected to a synchronous reset
  path, and flags `:full` signals that are used in logic that assumes
  they survive a soft reset.

      wire :dev_addr, 7, persist: :power_on_only
      wire :crc_reg, 16, persist: :full

  ## Width Encoding

  Width is normally a `pos_integer()`. For parameterized interfaces:

    - `{:param, atom()}` — width equals the named parameter value
    - `{:param, atom(), (pos_integer() -> pos_integer())}` — width is
      a function of a parameter value

  ## Source Locations

  The `source_location` field is populated by macros at expansion time
  and used by `Hw.Analysis` and the LSP server for diagnostics.
  """

  alias Hw.Analysis.Location

  @type direction  :: :input | :output | :inout | :internal
  @type signedness :: :signed | :unsigned
  @type sense      :: :high | :low
  @type endian     :: :little | :big
  @type persist    :: :full | :power_on_only
  @type pullmode   :: :none | :up | :down

  @type width ::
    pos_integer()
    | {:param, atom()}
    | {:param, atom(), (pos_integer() -> pos_integer())}

  @type t :: %__MODULE__{
    name:            atom(),
    width:           width(),
    signed:          signedness(),
    direction:       direction(),
    init:            integer() | nil,
    # Structural type annotations
    clock_domain:    atom() | nil,
    sense:           sense(),
    endian:          endian() | nil,
    persist:         persist(),
    pullmode:        pullmode(),
    source_location: Location.t() | nil
  }

  @enforce_keys [:name, :width, :signed, :direction]
  defstruct [
    :name, :width, :signed, :direction, :init,
    :clock_domain,
    :endian,
    sense:           :high,
    persist:         :full,
    pullmode:        :none,
    source_location: nil
  ]

  @doc "Create an input signal."
  @spec input(atom(), width(), keyword()) :: t()
  def input(name, width, opts \\ []) do
    %__MODULE__{
      name:            name,
      width:           width,
      signed:          Keyword.get(opts, :signed, :unsigned),
      direction:       :input,
      init:            nil,
      clock_domain:    Keyword.get(opts, :clock_domain),
      sense:           Keyword.get(opts, :sense, :high),
      endian:          Keyword.get(opts, :endian),
      persist:         Keyword.get(opts, :persist, :full),
      source_location: Keyword.get(opts, :source_location)
    }
  end

  @doc "Create an output signal."
  @spec output(atom(), width(), keyword()) :: t()
  def output(name, width, opts \\ []) do
    %__MODULE__{
      name:            name,
      width:           width,
      signed:          Keyword.get(opts, :signed, :unsigned),
      direction:       :output,
      init:            Keyword.get(opts, :init),
      clock_domain:    Keyword.get(opts, :clock_domain),
      sense:           Keyword.get(opts, :sense, :high),
      endian:          Keyword.get(opts, :endian),
      persist:         Keyword.get(opts, :persist, :full),
      source_location: Keyword.get(opts, :source_location)
    }
  end

  @doc "Create a bidirectional (tri-state) signal."
  @spec inout(atom(), width(), keyword()) :: t()
  def inout(name, width, opts \\ []) do
    %__MODULE__{
      name:            name,
      width:           width,
      signed:          Keyword.get(opts, :signed, :unsigned),
      direction:       :inout,
      init:            nil,
      clock_domain:    Keyword.get(opts, :clock_domain),
      sense:           Keyword.get(opts, :sense, :high),
      endian:          Keyword.get(opts, :endian),
      persist:         Keyword.get(opts, :persist, :full),
      pullmode:        Keyword.get(opts, :pullmode, :none),
      source_location: Keyword.get(opts, :source_location)
    }
  end

  @doc "Create an internal wire."
  @spec wire(atom(), width(), keyword()) :: t()
  def wire(name, width, opts \\ []) do
    %__MODULE__{
      name:            name,
      width:           width,
      signed:          Keyword.get(opts, :signed, :unsigned),
      direction:       :internal,
      init:            Keyword.get(opts, :init),
      clock_domain:    Keyword.get(opts, :clock_domain),
      sense:           Keyword.get(opts, :sense, :high),
      endian:          Keyword.get(opts, :endian),
      persist:         Keyword.get(opts, :persist, :full),
      source_location: Keyword.get(opts, :source_location)
    }
  end
end
