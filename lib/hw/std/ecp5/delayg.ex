defmodule Hw.ECP5.DELAYG do
  @moduledoc """
  ECP5 fixed delay line: `DEL_VALUE` taps between `a` and `z`, set at build
  time. `Hw.ECP5.DELAYF` is the run-time adjustable version.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :DEL_MODE, default: "USER_DEFINED"
  param :DEL_VALUE, default: 0

  input :a, 1
  output :z, 1

  blackbox :delay, "DELAYG",
    params: [DEL_MODE: :DEL_MODE, DEL_VALUE: :DEL_VALUE],
    ports: [A: :a, Z: :z]
end
