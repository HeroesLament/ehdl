defmodule FsmHandshakeSkewTest do
  use ExUnit.Case, async: true

  # --------------------------------------------------------------------------
  # Fixtures
  #
  # Each is the smallest component that isolates one behaviour of the rule.
  # They are deliberately not realistic designs — they exist so a regression in
  # the walker shows up as a failing assertion rather than as silence.
  # --------------------------------------------------------------------------

  # Both defects, reached through an `if`. `ready` is asserted in :idle and
  # never deasserted on the way out, and the transition tests only `valid`.
  defmodule BuggyIf do
    use Hw.Component

    clock :clk
    input :rst, 1
    input :valid, 1
    output :ready, 1
    output :busy, 1

    fsm :st, clock: :clk, reset: :rst, init: :idle do
      defaults do
        ready = 1
        busy = 0
      end

      case st do
        :idle ->
          ready = 1
          busy = 0

          on valid do
            next :work
          end

        :work ->
          ready = 0
          busy = 1

          on not valid do
            next :idle
          end
      end
    end
  end

  # The same two defects, but the transition is commanded from inside an
  # `hdl_case` rather than an `if`. This is the case the walker originally
  # missed entirely, and hdl_case is a core way to command state changes, so
  # missing it made the rule worthless for a large class of real FSMs.
  defmodule BuggyHdlCase do
    use Hw.Component

    clock :clk
    input :rst, 1
    input :valid, 1
    input :mode, 1
    output :ready, 1

    fsm :st, clock: :clk, reset: :rst, init: :idle do
      defaults do
        ready = 1
      end

      case st do
        :idle ->
          ready = 1

          hdl_case <<mode::1, valid::1>> do
            <<1::1, 1::1>> -> next :work
          end

        :work ->
          ready = 0

          on not valid do
            next :idle
          end
      end
    end
  end

  # Correct: both halves tested, and `ready` explicitly deasserted inside the
  # branch that transitions.
  defmodule Clean do
    use Hw.Component

    clock :clk
    input :rst, 1
    input :valid, 1
    output :ready, 1

    fsm :st, clock: :clk, reset: :rst, init: :idle do
      defaults do
        ready = 0
      end

      case st do
        :idle ->
          ready = 1

          on ready and valid do
            ready = 0
            next :work
          end

        :work ->
          ready = 0

          # Re-assert on the way back too, otherwise `ready` is low for the
          # first cycle of :idle — harmless, but it is what the stale-low
          # warning is for, and this fixture models the fully-correct pattern.
          on not valid do
            ready = 1
            next :idle
          end
      end
    end
  end

  @codes [:fsm_handshake_skew, :fsm_handshake_single_sided]

  defp findings(module) do
    Hw.Analysis.run([module]).diagnostics
    |> Enum.filter(&(&1.code in @codes))
  end

  defp codes(module), do: findings(module) |> Enum.map(& &1.code) |> Enum.sort()

  describe "transitions reached through if" do
    test "flags a handshake output held asserted into the next state" do
      assert :fsm_handshake_skew in codes(BuggyIf)
    end

    test "flags a transition that tests only the peer's half" do
      assert :fsm_handshake_single_sided in codes(BuggyIf)
    end

    test "held-asserted is an error, not a warning" do
      d = findings(BuggyIf) |> Enum.find(&(&1.code == :fsm_handshake_skew))
      assert d.severity == :error
    end

    test "ignores non-handshake outputs" do
      refute Enum.any?(findings(BuggyIf), &(&1.context[:signal] == :busy))
    end
  end

  describe "transitions reached through hdl_case" do
    test "flags a handshake output held asserted into the next state" do
      assert :fsm_handshake_skew in codes(BuggyHdlCase)
    end

    test "flags a single-sided hdl_case subject" do
      assert :fsm_handshake_single_sided in codes(BuggyHdlCase)
    end

    test "attributes the finding to the asserting state" do
      d = findings(BuggyHdlCase) |> Enum.find(&(&1.code == :fsm_handshake_skew))
      assert d.context[:signal] == :ready
      assert d.context[:state] == :idle
    end
  end

  describe "correct handshakes" do
    test "a both-sided, explicitly deasserted handshake is clean" do
      assert codes(Clean) == []
    end
  end
end
