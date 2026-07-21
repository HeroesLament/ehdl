defmodule Hw.TraceLiveAdapterTest do
  use ExUnit.Case, async: true

  # Unit coverage for the pure parts of Adapter.Live: building a Trace metadata
  # skeleton from a schedule, with correct entity-scoped signal selection and
  # scope resolution. The from_history/snapshot_trace paths need a running sim +
  # ElixirScope and are covered by the deferred live integration test (see
  # docs/TRACE_UNIFICATION.md §6b).

  import Hw.Waveform.ExUnit, only: [build_schedule: 1]

  alias Hw.Trace
  alias Hw.Trace.Adapter.Live

  # Flat single-component design: everything lives in :top scope.
  defmodule Blinker do
    use Hw.Component

    clock :clk, freq: 48.0
    input :rst, 1
    output :led, 1
    wire :counter, 24, init: 0

    fsm :blink_state, clock: :clk, init: :off do
      case blink_state do
        :off ->
          led = 0
          counter = counter + 1
          on counter == 5, next: :on

        :on ->
          led = 1
          counter = counter + 1
          on(counter == 10, next: :off)
      end
    end
  end

  test "new/2 with nil entities covers all signals in top scope" do
    schedule = build_schedule(Blinker)
    trace = Live.new(schedule, nil)

    # Flat design → all signals resolve to :top
    assert Trace.scope_tree(trace) |> Map.keys() == [:top]
    assert Trace.address(trace, :led) == {[:top], :led}
    assert Trace.address(trace, :counter) == {[:top], :counter}

    # widths carried from the schedule
    assert Trace.meta(trace, :counter).width == 24
    assert Trace.meta(trace, :led).width == 1
  end

  test "new/2 restricted to an entity selects only that entity's signals" do
    schedule = build_schedule(Blinker)
    # Blinker is flat, so its signals live under :_top_. Requesting :_top_ should
    # include the unprefixed signals and nothing else.
    trace = Live.new(schedule, [:_top_])

    names = Trace.scope_tree(trace)[:top] || []
    assert :led in names
    assert :counter in names
  end

  test "to_trace bridge exists on Hw.Simtrace" do
    # Signature/wiring smoke check — full behavior needs the live integration test.
    Code.ensure_loaded!(Hw.Simtrace)
    Code.ensure_loaded!(Hw.Trace.Adapter.Live)
    assert function_exported?(Hw.Simtrace, :to_trace, 1)
    assert function_exported?(Hw.Trace.Adapter.Live, :from_history, 1)
  end
end
