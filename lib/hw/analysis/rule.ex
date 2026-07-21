defmodule Hw.Analysis.Rule do
  @moduledoc """
  Behaviour for hardware analysis rules.

  Any module that adopts this behaviour and lives under `Hw.Analysis.Rules.*`
  is automatically discovered and run by `Hw.Analysis.run/1`.

  ## Defining a rule

      defmodule Hw.Analysis.Rules.MyRule do
        @behaviour Hw.Analysis.Rule
        @moduledoc "Checks for ..."

        # Optional: control execution order (default 50, lower = earlier)
        @impl Hw.Analysis.Rule
        def priority, do: 50

        @impl Hw.Analysis.Rule
        def run(metadata) do
          # Return a list of Hw.Analysis.Diagnostic.t()
          []
        end
      end

  ## Metadata fields

  The `metadata` map contains:

  - `:components`  — list of component metadata maps, each with:
      - `:module`     — the component module atom
      - `:signals`    — list of signal maps (name, width, direction, source_location)
      - `:clocks`     — list of clock maps (name, edge, freq_mhz)
      - `:instances`  — list of instance maps (name, module, connections)
      - `:interfaces` — list of interface binding maps
  - `:interfaces`  — list of interface metadata maps
  - `:connections` — list of cross-component connection maps
  """

  @doc """
  Run this rule against the collected design metadata.
  Returns a list of diagnostics (may be empty).
  """
  @callback run(Hw.Analysis.metadata()) :: [Hw.Analysis.Diagnostic.t()]

  @doc """
  Execution priority. Lower numbers run first.
  Rules that other rules depend on should have lower priority numbers.
  Default is 50.
  """
  @callback priority() :: non_neg_integer()

  @optional_callbacks [priority: 0]
end
