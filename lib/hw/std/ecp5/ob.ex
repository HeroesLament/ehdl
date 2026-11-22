defmodule Hw.ECP5.OB do
  @moduledoc """
  ECP5 output pad buffer. Top-level outputs get one implicitly; instantiate it
  when an output must come from a specific source without fabric in between
  (an `Hw.ECP5.ODDRX1F` Q, for instance).

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  input :i, 1
  output :o, 1

  blackbox :ob, "OB", ports: [I: :i, O: :o]
end
