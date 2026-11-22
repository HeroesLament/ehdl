defmodule Hw.ECP5.JTAGG do
  @moduledoc """
  ECP5 JTAG port tap into fabric: the two user instructions ER1 (0x32) and
  ER2 (0x38) select a fabric data register, so a host on the board's JTAG
  cable can talk to user logic (debug bridge, register access) without extra
  pins.

  `tck` / `tms` / `tdi` / `tdo` are the dedicated JTAG pins and are connected
  only so the primitive has its pads; the fabric side is `jtck`, `jtdi`,
  `jshift`, `jupdate`, `jrstn`, `jce1` / `jce2` (ER1 / ER2 selected),
  `jrti1` / `jrti2` (run-test-idle in ER1 / ER2), with `jtdo1` / `jtdo2`
  driven back by the fabric register.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :ER1, default: "ENABLED"
  param :ER2, default: "ENABLED"

  input :tck, 1
  input :tms, 1
  input :tdi, 1
  input :jtdo2, 1
  input :jtdo1, 1
  output :tdo, 1
  output :jtdi, 1
  output :jtck, 1
  output :jrti2, 1
  output :jrti1, 1
  output :jshift, 1
  output :jupdate, 1
  output :jrstn, 1
  output :jce2, 1
  output :jce1, 1

  blackbox :jtag, "JTAGG",
    params: [ER1: :ER1, ER2: :ER2],
    ports: [
      TCK: :tck,
      TMS: :tms,
      TDI: :tdi,
      JTDO2: :jtdo2,
      JTDO1: :jtdo1,
      TDO: :tdo,
      JTDI: :jtdi,
      JTCK: :jtck,
      JRTI2: :jrti2,
      JRTI1: :jrti1,
      JSHIFT: :jshift,
      JUPDATE: :jupdate,
      JRSTN: :jrstn,
      JCE2: :jce2,
      JCE1: :jce1
    ]
end
