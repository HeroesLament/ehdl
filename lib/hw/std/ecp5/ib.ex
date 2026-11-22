defmodule Hw.ECP5.IB do
  @moduledoc """
  ECP5 input pad buffer. Top-level inputs get one implicitly; instantiate it
  only when a pad must reach logic through an explicit buffer (for example a
  pad also used by a hard block).

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  input :i, 1
  output :o, 1

  blackbox :ib, "IB", ports: [I: :i, O: :o]
end
