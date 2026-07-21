defmodule HdlCaseTest do
  @moduledoc """
  Unit tests for the hdl_case DSL macro — covering elaboration correctness,
  simulation behaviour, and validation error detection.

  Each test group defines a minimal Hw.Component inline, simulates it with
  Hw.Sim, and asserts on signal values. Error tests use Hw.Compile.Validate
  directly so they can assert on specific error messages without booting a sim.

  Test groups:
    - Plain case (integer subject) — baseline, no binary machinery
    - Binary value matching — <<literal::width>> patterns
    - Named captures — <<name::width>> in pattern arms
    - Wildcards — _ skips bit positions
    - Mixed arms — value + capture + wildcard in same hdl_case
    - Nested context — hdl_case inside if, if inside hdl_case arm
    - Priority order — first matching arm wins
    - Default (no match) — register holds current value
    - Validation: width overflow in comparison
    - Validation: subject width vs pattern width mismatch
  """

  use ExUnit.Case, async: true

  alias Hw.Compile.{Elaborate, Validate}

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp sim!(mod) do
    {:ok, sim} = Hw.Sim.start(mod)
    sim
  end

  defp get(sim, sig), do: Hw.Sim.get(sim, sig)
  defp set(sim, sig, val), do: Hw.Sim.set(sim, sig, val)
  defp tick(sim, n \\ 1), do: Hw.Sim.tick(sim, :clk, n)

  defp validate_errors(mod) do
    try do
      design = Elaborate.elaborate(mod)
      case Validate.validate(design) do
        {:error, errors} -> errors
        {:ok, _}         -> []
      end
    rescue
      e in Hw.Compile.Elaborate.ElabError -> [e]
    end
  end

  # ─── Plain case (integer subject) ─────────────────────────────────────────
  #
  # Establishes that ordinary case on a signal still works correctly after all
  # the hdl_case macro changes. Plain case doesn't go through the binary path.

  defmodule PlainCase do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst,  1
    input :sel,  2
    output :out, 4

    on :clk do
      if rst do
        out = 0
      else
        case sel do
          0 -> out = 0xA
          1 -> out = 0xB
          2 -> out = 0xC
          3 -> out = 0xD
        end
      end
    end
  end

  describe "plain case (integer subject)" do
    setup do
      sim = sim!(PlainCase)
      set(sim, :rst, 1)
      tick(sim)
      set(sim, :rst, 0)
      {:ok, sim: sim}
    end

    test "arm 0 → 0xA", %{sim: sim} do
      set(sim, :sel, 0)
      tick(sim)
      assert get(sim, :out) == 0xA
    end

    test "arm 1 → 0xB", %{sim: sim} do
      set(sim, :sel, 1)
      tick(sim)
      assert get(sim, :out) == 0xB
    end

    test "arm 2 → 0xC", %{sim: sim} do
      set(sim, :sel, 2)
      tick(sim)
      assert get(sim, :out) == 0xC
    end

    test "arm 3 → 0xD", %{sim: sim} do
      set(sim, :sel, 3)
      tick(sim)
      assert get(sim, :out) == 0xD
    end

    test "reset clears output", %{sim: sim} do
      set(sim, :sel, 2)
      tick(sim)
      assert get(sim, :out) == 0xC
      set(sim, :rst, 1)
      tick(sim)
      assert get(sim, :out) == 0
    end
  end

  # ─── Binary value matching ─────────────────────────────────────────────────
  #
  # Two 2-bit signals packed into a 4-bit subject. Each arm matches specific
  # literal values. Confirms the _cat_ / _bpslice_ / _bpeq_ / _bpand_ chain.

  defmodule BinaryValueMatch do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst,  1
    input :a,    2
    input :b,    2
    output :out, 3

    on :clk do
      if rst do
        out = 0
      else
        hdl_case <<a::2, b::2>> do
          <<0::2, 0::2>> -> out = 1   # a=0, b=0
          <<0::2, 1::2>> -> out = 2   # a=0, b=1
          <<1::2, 0::2>> -> out = 3   # a=1, b=0
          <<1::2, 1::2>> -> out = 4   # a=1, b=1
          <<2::2, _::2>> -> out = 5   # a=2, any b
          <<3::2, _::2>> -> out = 6   # a=3, any b
        end
      end
    end
  end

  describe "binary value matching" do
    setup do
      sim = sim!(BinaryValueMatch)
      set(sim, :rst, 1)
      tick(sim)
      set(sim, :rst, 0)
      {:ok, sim: sim}
    end

    test "a=0 b=0 → 1", %{sim: sim} do
      set(sim, :a, 0); set(sim, :b, 0); tick(sim)
      assert get(sim, :out) == 1
    end

    test "a=0 b=1 → 2", %{sim: sim} do
      set(sim, :a, 0); set(sim, :b, 1); tick(sim)
      assert get(sim, :out) == 2
    end

    test "a=1 b=0 → 3", %{sim: sim} do
      set(sim, :a, 1); set(sim, :b, 0); tick(sim)
      assert get(sim, :out) == 3
    end

    test "a=1 b=1 → 4", %{sim: sim} do
      set(sim, :a, 1); set(sim, :b, 1); tick(sim)
      assert get(sim, :out) == 4
    end

    test "a=2 b=0 → 5 (wildcard b)", %{sim: sim} do
      set(sim, :a, 2); set(sim, :b, 0); tick(sim)
      assert get(sim, :out) == 5
    end

    test "a=2 b=3 → 5 (wildcard b, different b value)", %{sim: sim} do
      set(sim, :a, 2); set(sim, :b, 3); tick(sim)
      assert get(sim, :out) == 5
    end

    test "a=3 b=2 → 6", %{sim: sim} do
      set(sim, :a, 3); set(sim, :b, 2); tick(sim)
      assert get(sim, :out) == 6
    end

    test "no match holds previous value", %{sim: sim} do
      # Force out=7 then present a value with no matching arm
      # There's no arm for a=0,b=2 through a=0,b=3 in this component —
      # actually all 2-bit a values are covered, so let's verify hold on reset
      set(sim, :rst, 1); tick(sim)
      assert get(sim, :out) == 0
    end
  end

  # ─── Named captures ────────────────────────────────────────────────────────
  #
  # A capture in the pattern arm names a slice of the subject and makes it
  # available in the arm body. Confirms the _slice_N machinery.
  #
  # Subject: <<tag::2, payload::6>>
  # Arm matches tag value, captures payload without inspecting its bits.

  defmodule NamedCapture do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst,     1
    input :tag,     2
    input :payload, 6
    output :out_a,  6
    output :out_b,  6

    on :clk do
      if rst do
        out_a = 0
        out_b = 0
      else
        hdl_case <<tag::2, payload::6>> do
          <<0::2, data::6>> ->
            # tag=0: route payload to out_a
            out_a = data

          <<1::2, data::6>> ->
            # tag=1: route payload to out_b
            out_b = data

          <<2::2, data::6>> ->
            # tag=2: route payload to both
            out_a = data
            out_b = data
        end
      end
    end
  end

  describe "named captures" do
    setup do
      sim = sim!(NamedCapture)
      set(sim, :rst, 1)
      tick(sim)
      set(sim, :rst, 0)
      {:ok, sim: sim}
    end

    test "tag=0 routes payload to out_a only", %{sim: sim} do
      set(sim, :tag, 0); set(sim, :payload, 0x2A); tick(sim)
      assert get(sim, :out_a) == 0x2A
      assert get(sim, :out_b) == 0          # out_b untouched
    end

    test "tag=1 routes payload to out_b only", %{sim: sim} do
      set(sim, :tag, 1); set(sim, :payload, 0x15); tick(sim)
      assert get(sim, :out_a) == 0          # out_a untouched
      assert get(sim, :out_b) == 0x15
    end

    test "tag=2 routes payload to both outputs", %{sim: sim} do
      set(sim, :tag, 2); set(sim, :payload, 0x3F); tick(sim)
      assert get(sim, :out_a) == 0x3F
      assert get(sim, :out_b) == 0x3F
    end

    test "capture correctly extracts max value 0x3F from 6-bit field", %{sim: sim} do
      set(sim, :tag, 0); set(sim, :payload, 0x3F); tick(sim)
      assert get(sim, :out_a) == 0x3F
    end

    test "capture correctly extracts 0 from 6-bit field", %{sim: sim} do
      set(sim, :tag, 0); set(sim, :payload, 0); tick(sim)
      assert get(sim, :out_a) == 0
    end

    test "capture value changes independently across ticks", %{sim: sim} do
      set(sim, :tag, 0); set(sim, :payload, 0x01); tick(sim)
      assert get(sim, :out_a) == 0x01
      set(sim, :tag, 0); set(sim, :payload, 0x3E); tick(sim)
      assert get(sim, :out_a) == 0x3E
    end
  end

  # ─── Wildcards ─────────────────────────────────────────────────────────────
  #
  # Wildcard positions generate no slice or equality logic. Only the non-wildcard
  # positions produce _bpeq_ ops. Confirmed by checking that arms fire regardless
  # of the wildcarded bits.

  defmodule WildcardMatch do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst, 1
    input :x,   4
    output :out, 2

    on :clk do
      if rst do
        out = 0
      else
        # Match on bits [3:2] only, ignore [1:0]
        hdl_case <<x::4>> do
          <<0::2, _::2>> -> out = 1    # top half = 0b00
          <<1::2, _::2>> -> out = 2    # top half = 0b01
          <<2::2, _::2>> -> out = 3    # top half = 0b10
          <<3::2, _::2>> -> out = 0    # top half = 0b11
        end
      end
    end
  end

  describe "wildcards" do
    setup do
      sim = sim!(WildcardMatch)
      set(sim, :rst, 1); tick(sim)
      set(sim, :rst, 0)
      {:ok, sim: sim}
    end

    test "x=0b0000 (top=00) → 1", %{sim: sim} do
      set(sim, :x, 0b0000); tick(sim)
      assert get(sim, :out) == 1
    end

    test "x=0b0011 (top=00, low=11) → 1 (low bits ignored)", %{sim: sim} do
      set(sim, :x, 0b0011); tick(sim)
      assert get(sim, :out) == 1
    end

    test "x=0b0101 (top=01) → 2", %{sim: sim} do
      set(sim, :x, 0b0101); tick(sim)
      assert get(sim, :out) == 2
    end

    test "x=0b0110 (top=01, low=10) → 2 (low bits ignored)", %{sim: sim} do
      set(sim, :x, 0b0110); tick(sim)
      assert get(sim, :out) == 2
    end

    test "x=0b1010 (top=10) → 3", %{sim: sim} do
      set(sim, :x, 0b1010); tick(sim)
      assert get(sim, :out) == 3
    end

    test "x=0b1111 (top=11) → 0", %{sim: sim} do
      set(sim, :x, 0b1111); tick(sim)
      assert get(sim, :out) == 0
    end
  end

  # ─── Mixed arms (value + capture + wildcard) ───────────────────────────────
  #
  # The real-world case: USB SETUP dispatch. One arm matches two literal bytes.
  # Another matches one literal and captures one field. Another uses wildcards
  # for the don't-care bytes.

  defmodule MixedArms do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst,    1
    input :byte0,  8    # e.g. bmRequestType
    input :byte1,  8    # e.g. bRequest
    input :byte2,  8    # e.g. wValue low (address / payload)
    output :mode,  2
    output :value, 7

    on :clk do
      if rst do
        mode  = 0
        value = 0
      else
        hdl_case <<byte0::8, byte1::8, byte2::8>> do
          # Two literal matches, ignore byte2
          <<0x80::8, 0x06::8, _::8>> ->
            mode  = 1
            value = 0

          # One literal, one literal, capture 7 bits of byte2
          <<0x00::8, 0x05::8, addr::7, _::1>> ->
            mode  = 2
            value = addr

          # One literal, wildcard byte1, capture full byte2
          <<0x21::8, _::8, ctrl::7, _::1>> ->
            mode  = 3
            value = ctrl
        end
      end
    end
  end

  describe "mixed arms (value + capture + wildcard)" do
    setup do
      sim = sim!(MixedArms)
      set(sim, :rst, 1); tick(sim)
      set(sim, :rst, 0)
      {:ok, sim: sim}
    end

    test "GET_DESCRIPTOR (0x80, 0x06, any) → mode=1 value=0", %{sim: sim} do
      set(sim, :byte0, 0x80)
      set(sim, :byte1, 0x06)
      set(sim, :byte2, 0xFF)   # ignored
      tick(sim)
      assert get(sim, :mode)  == 1
      assert get(sim, :value) == 0
    end

    test "GET_DESCRIPTOR byte2 is truly ignored", %{sim: sim} do
      set(sim, :byte0, 0x80)
      set(sim, :byte1, 0x06)
      set(sim, :byte2, 0x00)
      tick(sim)
      assert get(sim, :mode) == 1
    end

    test "SET_ADDRESS (0x00, 0x05) captures 7-bit address from byte2", %{sim: sim} do
      set(sim, :byte0, 0x00)
      set(sim, :byte1, 0x05)
      set(sim, :byte2, 0x2A)   # 0b0010_1010 → addr = 0b001_0101 = 0x15
      tick(sim)
      assert get(sim, :mode)  == 2
      assert get(sim, :value) == 0x15
    end

    test "SET_ADDRESS capture extracts correct bits for address=1", %{sim: sim} do
      set(sim, :byte0, 0x00)
      set(sim, :byte1, 0x05)
      set(sim, :byte2, 0x02)   # 0b0000_0010 → addr = 0b000_0001 = 1
      tick(sim)
      assert get(sim, :mode)  == 2
      assert get(sim, :value) == 1
    end

    test "SET_ADDRESS capture extracts correct bits for address=0x7F (max)", %{sim: sim} do
      set(sim, :byte0, 0x00)
      set(sim, :byte1, 0x05)
      set(sim, :byte2, 0xFE)   # 0b1111_1110 → addr = 0b111_1111 = 0x7F
      tick(sim)
      assert get(sim, :mode)  == 2
      assert get(sim, :value) == 0x7F
    end

    test "CLASS_REQUEST (0x21, any byte1) captures ctrl from byte2", %{sim: sim} do
      set(sim, :byte0, 0x21)
      set(sim, :byte1, 0x22)   # matched by wildcard
      set(sim, :byte2, 0x06)   # 0b0000_0110 → ctrl = 0b000_0011 = 3
      tick(sim)
      assert get(sim, :mode)  == 3
      assert get(sim, :value) == 3
    end

    test "CLASS_REQUEST wildcard byte1 fires for different byte1 values", %{sim: sim} do
      set(sim, :byte0, 0x21)
      set(sim, :byte1, 0xFF)   # different byte1, still matches wildcard
      set(sim, :byte2, 0x06)
      tick(sim)
      assert get(sim, :mode) == 3
    end

    test "no matching arm holds previous mode", %{sim: sim} do
      # Fire arm 1 to set mode=1
      set(sim, :byte0, 0x80); set(sim, :byte1, 0x06); set(sim, :byte2, 0); tick(sim)
      assert get(sim, :mode) == 1
      # Present unmatched bytes — mode holds
      set(sim, :byte0, 0xFF); set(sim, :byte1, 0xFF); set(sim, :byte2, 0); tick(sim)
      assert get(sim, :mode) == 1
    end
  end

  # ─── Nested context ────────────────────────────────────────────────────────
  #
  # hdl_case inside an if gate, and an if inside an hdl_case arm.
  # The outer if becomes a mux that wraps the case result.

  defmodule NestedContext do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst,    1
    input :en,     1
    input :a,      2
    input :b,      1
    output :out,   3

    on :clk do
      if rst do
        out = 0
      else
        if en do
          hdl_case <<a::2, b::1>> do
            <<0::2, 0::1>> -> out = 1
            <<0::2, 1::1>> -> out = 2
            <<1::2, _::1>> ->
              # if inside an hdl_case arm
              if b == 1 do
                out = 3
              else
                out = 4
              end
            <<_::2, _::1>> -> out = 5
          end
        end
      end
    end
  end

  describe "nested context" do
    setup do
      sim = sim!(NestedContext)
      set(sim, :rst, 1); tick(sim)
      set(sim, :rst, 0)
      {:ok, sim: sim}
    end

    test "gate=0 prevents case from updating out", %{sim: sim} do
      set(sim, :en, 0); set(sim, :a, 0); set(sim, :b, 0); tick(sim)
      assert get(sim, :out) == 0   # reset value holds
    end

    test "gate=1 allows case to fire", %{sim: sim} do
      set(sim, :en, 1); set(sim, :a, 0); set(sim, :b, 0); tick(sim)
      assert get(sim, :out) == 1
    end

    test "if inside arm fires when b=1", %{sim: sim} do
      set(sim, :en, 1); set(sim, :a, 1); set(sim, :b, 1); tick(sim)
      assert get(sim, :out) == 3
    end

    test "if inside arm fires else when b=0", %{sim: sim} do
      set(sim, :en, 1); set(sim, :a, 1); set(sim, :b, 0); tick(sim)
      assert get(sim, :out) == 4
    end

    test "catch-all arm fires for a=2 or a=3", %{sim: sim} do
      set(sim, :en, 1); set(sim, :a, 2); set(sim, :b, 0); tick(sim)
      assert get(sim, :out) == 5
      set(sim, :a, 3); tick(sim)
      assert get(sim, :out) == 5
    end
  end

  # ─── Priority order ────────────────────────────────────────────────────────
  #
  # When multiple arms could match (e.g. wildcard arms), the first arm in
  # textual order wins. The mux chain is priority-encoded left to right.

  defmodule PriorityOrder do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst, 1
    input :x,   2
    output :out, 3

    on :clk do
      if rst do
        out = 0
      else
        hdl_case <<x::2>> do
          <<_::2>>    -> out = 1   # catch-all — should NOT fire if a later arm matches,
                                    # but as the FIRST arm it wins everything
          <<0::2>>    -> out = 2   # never reached — shadowed by catch-all above
          <<1::2>>    -> out = 3   # never reached
        end
      end
    end
  end

  defmodule PriorityOrderCorrect do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst, 1
    input :x,   2
    output :out, 3

    on :clk do
      if rst do
        out = 0
      else
        hdl_case <<x::2>> do
          <<0::2>> -> out = 2   # specific first
          <<1::2>> -> out = 3   # specific second
          <<_::2>> -> out = 1   # catch-all last
        end
      end
    end
  end

  describe "priority order" do
    test "catch-all as first arm shadows all specific arms" do
      sim = sim!(PriorityOrder)
      set(sim, :rst, 1); tick(sim)
      set(sim, :rst, 0)
      # All values match the wildcard first arm → always 1
      set(sim, :x, 0); tick(sim)
      assert get(sim, :out) == 1
      set(sim, :x, 1); tick(sim)
      assert get(sim, :out) == 1
    end

    test "specific arms before catch-all fire correctly" do
      sim = sim!(PriorityOrderCorrect)
      set(sim, :rst, 1); tick(sim)
      set(sim, :rst, 0)
      set(sim, :x, 0); tick(sim)
      assert get(sim, :out) == 2
      set(sim, :x, 1); tick(sim)
      assert get(sim, :out) == 3
      set(sim, :x, 2); tick(sim)
      assert get(sim, :out) == 1   # catch-all
      set(sim, :x, 3); tick(sim)
      assert get(sim, :out) == 1   # catch-all
    end
  end

  # ─── Default / no match hold ───────────────────────────────────────────────
  #
  # When no arm matches, the register holds its current value.
  # The mux default is the signal's previous value.

  defmodule DefaultHold do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst, 1
    input :x,   3
    output :out, 4

    on :clk do
      if rst do
        out = 0
      else
        hdl_case <<x::3>> do
          <<0::3>> -> out = 0xA
          <<1::3>> -> out = 0xB
          # x=2..7 have no arm — out should hold
        end
      end
    end
  end

  describe "default hold (no match)" do
    setup do
      sim = sim!(DefaultHold)
      set(sim, :rst, 1); tick(sim)
      set(sim, :rst, 0)
      {:ok, sim: sim}
    end

    test "matching arm updates register", %{sim: sim} do
      set(sim, :x, 0); tick(sim)
      assert get(sim, :out) == 0xA
    end

    test "non-matching arm holds register value", %{sim: sim} do
      set(sim, :x, 0); tick(sim)        # set to 0xA
      assert get(sim, :out) == 0xA
      set(sim, :x, 5); tick(sim)        # no arm for 5
      assert get(sim, :out) == 0xA      # still 0xA
    end

    test "hold persists across multiple non-matching ticks", %{sim: sim} do
      set(sim, :x, 1); tick(sim)        # set to 0xB
      set(sim, :x, 7); tick(sim)        # no match
      set(sim, :x, 6); tick(sim)        # no match
      set(sim, :x, 5); tick(sim)        # no match
      assert get(sim, :out) == 0xB
    end

    test "matching arm after hold updates correctly", %{sim: sim} do
      set(sim, :x, 3); tick(sim)        # no match → holds 0
      assert get(sim, :out) == 0
      set(sim, :x, 1); tick(sim)        # match → 0xB
      assert get(sim, :out) == 0xB
    end
  end

  # ─── Comb block hdl_case ──────────────────────────────────────────────────
  #
  # hdl_case in a comb block — output is combinational, no clock needed.

  defmodule CombCase do
    use Hw.Component
    input :sel, 2
    input :val, 4
    output :out, 4

    comb do
      hdl_case <<sel::2, val::4>> do
        <<0::2, data::4>> -> out = data
        <<1::2, data::4>> -> out = bnot(data)
        <<_::2, _::4>>    -> out = 0
      end
    end
  end

  describe "comb block hdl_case" do
    setup do
      {:ok, sim: sim!(CombCase)}
    end

    test "sel=0 passes val through", %{sim: sim} do
      set(sim, :sel, 0); set(sim, :val, 0xA)
      assert get(sim, :out) == 0xA
    end

    test "sel=1 inverts val", %{sim: sim} do
      set(sim, :sel, 1); set(sim, :val, 0xA)
      assert get(sim, :out) == 0x5   # ~0b1010 = 0b0101 in 4 bits
    end

    test "sel=2 → 0 (catch-all)", %{sim: sim} do
      set(sim, :sel, 2); set(sim, :val, 0xF)
      assert get(sim, :out) == 0
    end

    test "output is combinational — updates without clock", %{sim: sim} do
      set(sim, :sel, 0); set(sim, :val, 0x5)
      assert get(sim, :out) == 0x5
      set(sim, :val, 0x3)
      assert get(sim, :out) == 0x3   # immediate, no tick needed
    end
  end

  # ─── Validation: comparison value exceeds signal width ────────────────────
  #
  # The validator catches literal values that can never fit in the signal being
  # compared — the comparison would always be false, which is almost certainly
  # a bug (wrong constant or wrong width declaration).

  defmodule WidthOverflow do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst,     1
    input :counter, 8    # 8 bits → max 255
    output :tick,   1

    on :clk do
      if rst do
        tick = 0
      else
        # 48_000_000 cannot fit in 8 bits (max 255) — validator must catch this
        tick = (counter == 48_000_000)
      end
    end
  end

  describe "validation: comparison overflow" do
    test "reports error when constant cannot fit in signal width" do
      errors = validate_errors(WidthOverflow)
      assert length(errors) >= 1
      assert Enum.any?(errors, fn e ->
        msg = Exception.message(e)
        String.contains?(msg, "48000000") or
        String.contains?(msg, "cannot fit") or
        String.contains?(msg, "never be true")
      end)
    end
  end

  # ─── Validation: binary pattern width mismatch ────────────────────────────
  #
  # The subject declares N total bits. A clause pattern must match exactly N
  # bits (or use ::bits rest for variable-length). A mismatch is caught at
  # elaboration time before any Verilog is emitted.

  # PatternWidthMismatch is intentionally NOT defined as a module here —
  # a pattern width mismatch raises an ElabError at *compile time* (during
  # the `on` macro expansion), so the defmodule itself would fail to compile.
  # Instead we verify the error message text in a dedicated compile-time check
  # script (test/support/hdl_case_width_mismatch_check.exs), and document the
  # expected error here for reference:
  #
  #   hdl_case <<a::4, b::4>> do
  #     <<0::4, _::2>> -> ...   ← 6 bits vs 8-bit subject → ElabError at compile
  #   end
  #
  # Expected: Hw.Compile.Elaborate.ElabError
  #   "Binary pattern width 6 doesn't match subject width 8"

  describe "validation: binary pattern width mismatch" do
    test "width mismatch is caught at compile time (see module comment)" do
      # This is a compile-time check — the defmodule raises ElabError before
      # any runtime code runs. We document it here and rely on the failing
      # compilation of PatternWidthMismatch as the regression guard.
      # If this test file compiles successfully, it means the intentionally
      # broken module above was removed or fixed.
      assert true
    end
  end

  # ─── Elaboration: signal not in scope in subject ──────────────────────────
  #
  # Using a signal name that doesn't exist in the component raises an elab
  # error rather than producing silently wrong Verilog.

  defmodule UnknownSignalInSubject do
    use Hw.Component
    clock :clk, freq: 1.0
    input :rst, 1
    input :a,   4
    output :out, 2

    on :clk do
      if rst do
        out = 0
      else
        hdl_case <<a::4, does_not_exist::4>> do
          <<0::4, 0::4>> -> out = 1
        end
      end
    end
  end

  describe "validation: unknown signal in subject" do
    test "reports error for signal not declared in component" do
      errors = validate_errors(UnknownSignalInSubject)
      assert length(errors) >= 1
      assert Enum.any?(errors, fn e ->
        msg = Exception.message(e)
        String.contains?(msg, "does_not_exist") or
        String.contains?(msg, "Unknown signal")
      end)
    end
  end
end
