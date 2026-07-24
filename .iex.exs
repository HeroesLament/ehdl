# Boot ElixirScope's TraceDB (backs the live Simtrace path) if available.
if Code.ensure_loaded?(ElixirScope) and is_nil(Process.whereis(ElixirScope.TraceDB)) do
  ElixirScope.setup(tracing_level: :states_only)
end

# ---------------------------------------------------------------------------
# Interactive convenience layer for the unified trace subsystem.
#
# Only affects the IEx prompt — never compilation or tests. Lets you drive a
# sim and poke at a trace without fully-qualified module names:
#
#     sched = Hw.Waveform.ExUnit.build_schedule(MyDesign)
#     {:ok, sim} = Backend.init(Backend.Nif, sched)
#     trace = Adapter.Nif.new(sched, signals: [:led, :counter])
#     {sim, trace} = Adapter.Nif.step_wave_each(sim, trace, :clk, 16)
#
#     find_when(trace, [], led: 1)          # bare, via `import`
#     transitions(trace, [], :led)
#     diff(trace, [], {:index, 2}, {:index, 5})
#     IO.puts Render.ascii(trace, width: 60)
#     assert_reaches(trace, "cdc.dev_state", 2, by: 2000)
# ---------------------------------------------------------------------------

# Aliases — short module names at the prompt.
alias Hw.Trace
alias Hw.Trace.{Render, VCD, Scope}
alias Hw.Trace.Adapter
alias Hw.Sim
alias Hw.Sim.Backend
alias Hw.Simtrace

# Imports — bare query + assertion verbs.
# (`import` is a macro requiring a literal module; import each directly.)
import Hw.Trace.Query
# ExUnit also re-exports find_when/3; exclude it so `find_when` stays unambiguous.
import Hw.Trace.ExUnit, except: [find_when: 3]

# ---------------------------------------------------------------------------
# Board — drive the live ULX3S over US1 (FTDI diagnostic UART) from IEx.
#
#   Board.flash()          # reconfigure FPGA (= true power-on reset). Use this,
#                          #   NOT Board.reenum(), to clean-reset for a re-test:
#                          #   dev_addr is persist: power_on_only and survives the
#                          #   'R' soft re-enum, so 'R' leaves us deaf at the old
#                          #   address while the host restarts at 0.
#   Board.read(8)          # bounded dashboard capture (raw string)
#   Board.reenum()         # send 'R' over US1 (soft re-enum; see caveat above)
#   Board.decode(raw)      # -> %{dev:, q:, tc:, lines:}
#   Board.sticky(raw)      # -> sticky latch map (DEV/GD/CF/MV/STP/ACC/PKT/TC)
#   Board.enum()           # flash + settle + return sticky map (one clean run)
#   Board.watch(n, secs)   # poll n times, print GD/Q/TC each
#
# TC nibbles: [3:0]=adopt [7:4]=indone [11:8]=inep0 [15:12]=nak.
# NEVER File.open the port from the BEAM — the fd leaks past process death and
# wedges every reader. Board.read shells out to `cat` with a bounded window.
# ---------------------------------------------------------------------------
defmodule Board do
  import Bitwise
  @port "/dev/cu.usbserial-D01477"
  @bit "designs/hello_board/build/hello_board_top.bit"

  def port, do: @port

  def read(secs \\ 8) do
    cmd =
      "pkill -9 -f 'cat /dev/cu' 2>/dev/null; " <>
        "( cat #{@port} & CP=$!; sleep #{secs}; kill $CP 2>/dev/null ) | tr -cd '[:print:]\n'"

    {out, _} = System.cmd("bash", ["-c", cmd], stderr_to_stdout: true, env: [{"LC_ALL", "C"}])
    out
  end

  def flash do
    {out, rc} =
      System.cmd("bash", ["-c", "pkill -9 -f 'cat /dev/cu' 2>/dev/null; fujprog #{@bit}"],
        stderr_to_stdout: true
      )

    ok = String.contains?(out, "100%")
    IO.puts(if ok, do: "flashed ok", else: out)
    {if(ok, do: :ok, else: :error), rc}
  end

  def reenum do
    System.cmd("bash", ["-c", "printf 'R' > #{@port}"])
    :sent
  end

  def decode(raw) do
    %{
      lines: length(Regex.scan(~r/PLL1/, raw)),
      dev: Regex.scan(~r/DEV(\d)/, raw) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq() |> Enum.sort(),
      q: Regex.scan(~r/Q=([0-9a-f]{4})/, raw) |> Enum.map(&Enum.at(&1, 1)) |> Enum.frequencies(),
      tc: Regex.scan(~r/TC([0-9a-f]{12})/, raw) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()
    }
  end

  # Extract each field INDEPENDENTLY across the whole capture (last occurrence),
  # so a line truncated by the bounded read can't drop a late field like TC.
  defp last_field(raw, re) do
    case Regex.scan(re, raw) do
      [] -> nil
      ms -> ms |> List.last() |> List.last()
    end
  end

  def sticky(raw) do
    base =
      for f <- ~w(DEV GD DR CF MV STP ACC PKT), into: %{} do
        {f, last_field(raw, ~r/#{f}(\d)/) || "?"}
      end

    tc = last_field(raw, ~r/TC([0-9a-f]{12})/)
    Map.merge(base, %{"TC" => tc || "?", "counts" => tc_counts(tc)})
  end

  # TC packed status word -> named counts. Nibbles (hex, LSB-first):
  # [3:0]=adopt [7:4]=indone [11:8]=inep0 [15:12]=nak (low 3 bytes carry them).
  def tc_counts(nil), do: nil

  def tc_counts(tc) when is_binary(tc) do
    v = String.to_integer(tc, 16)

    %{
      adopt: v &&& 0xF,
      indone: v >>> 4 &&& 0xF,
      inep0: v >>> 8 &&& 0xF,
      nak: v >>> 12 &&& 0xF
    }
  end

  # One clean enumeration: flash (power-on reset) then read the accumulated latches.
  def enum(wait_ms \\ 9000) do
    flash()
    Process.sleep(wait_ms)
    read(9) |> sticky()
  end

  def watch(n \\ 3, secs \\ 6) do
    for i <- 1..n do
      r = read(secs)
      s = sticky(r)
      qs = decode(r).q |> Map.keys()
      IO.puts("poll #{i}: GD=#{s["GD"]} DEV=#{s["DEV"]} Qseen=#{inspect(qs)} TC=#{s["TC"]}")
    end

    :ok
  end
end

IO.puts([
  IO.ANSI.faint(),
  "ehdl: trace helpers loaded — Trace, Query (find_when/transitions/diff), ",
  "Render, VCD, Backend, Sim, Simtrace. Board.flash/read/enum/watch for live HW. See .iex.exs.",
  IO.ANSI.reset()
])
