defmodule Hw.Waveform.ExUnit do
  @moduledoc """
  ExUnit helpers for waveform-driven hardware testing.

  Import this module in your test file to get `assert_waveform/2` and
  related helpers. The primary goal is Hardcaml-style expect tests where
  the waveform output becomes the diffable test artifact.

  ## Usage

      defmodule MyCounter.WaveformTest do
        use ExUnit.Case
        import Hw.Waveform.ExUnit

        test "counter increments on each clock edge" do
          schedule = build_schedule(MyCounter)
          {:ok, sim} = Hw.Sim.Backend.init(Hw.Sim.Backend.Nif, schedule)
          waves = Hw.Waveform.new(schedule, signals: [:clr, :incr, :count])

          {sim, waves} = sim
            |> Hw.Sim.Backend.poke!(:clr, 0)
            |> Hw.Sim.Backend.poke!(:incr, 1)
            |> then(fn s -> Hw.Sim.Backend.step_wave(s, waves, :clk, 3) end)

          assert_waveform waves, \"\"\"
          cycle   0 1 2
          clr     _ _ _
          incr    ‾ ‾ ‾
          count   1─2─3
          \"\"\"
        end
      end

  ## assert_waveform format

  The expected string is compared against `Hw.Waveform.render/2` output
  after normalising whitespace. Differences are shown as a clear diff.

  Signal rows follow the same rendering rules as `Hw.Waveform.render/2`:
  - 1-bit: `_` (low), `‾` (high), `/` (rising), `\\` (falling)
  - Multi-bit: decimal value runs separated by `─` continuation marks

  The cycle header line is optional in the expected string.

  ## print_waveform

  During development, use `print_waveform/2` to see the actual waveform
  output without asserting. Replace with `assert_waveform/2` once correct.

      print_waveform waves
      print_waveform waves, signals: [:rx_state, :valid]
  """

  alias Hw.Waveform

  # ---------------------------------------------------------------------------
  # Primary assertion
  # ---------------------------------------------------------------------------

  @doc """
  Assert that the rendered waveform matches the expected ASCII string.

  The comparison is whitespace-normalised (leading/trailing whitespace per
  line, blank lines around the block). Signal order must match.

  Raises `ExUnit.AssertionError` with a diff on mismatch.

      assert_waveform waves, \"\"\"
      cycle   0 1 2
      rst_n   ‾ ‾ ‾
      incr    _ ‾ ‾
      count   0─1─2
      \"\"\"
  """
  defmacro assert_waveform(waves, expected, opts \\ []) do
    quote bind_quoted: [waves: waves, expected: expected, opts: opts] do
      Hw.Waveform.ExUnit.__assert_waveform__(waves, expected, opts)
    end
  end

  @doc false
  def __assert_waveform__(waves, expected, opts) do
    actual = Waveform.render(waves, opts)

    norm_actual   = normalise(actual)
    norm_expected = normalise(expected)

    if norm_actual != norm_expected do
      raise ExUnit.AssertionError,
        left:    norm_actual,
        right:   norm_expected,
        message: waveform_diff_message(norm_actual, norm_expected),
        expr:    quote(do: assert_waveform)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Development helpers
  # ---------------------------------------------------------------------------

  @doc """
  Print the waveform to stdout. Returns `:ok`. Does not assert.

  Use during test development to capture the expected string:

      print_waveform waves
      print_waveform waves, signals: [:rx_state, :valid], from: 5, to: 15
  """
  @spec print_waveform(Waveform.t(), keyword()) :: :ok
  def print_waveform(%Waveform{} = waves, opts \\ []) do
    rendered = Waveform.render(waves, opts)
    IO.puts("\n" <> rendered)
    :ok
  end

  @doc """
  Assert a signal's value at a specific cycle.

  Raises with a clear message on mismatch.

      assert_at waves, :count, cycle: 3, value: 3
  """
  @spec assert_at(Waveform.t(), atom(), keyword()) :: :ok
  def assert_at(%Waveform{} = waves, signal, opts) do
    cycle    = Keyword.fetch!(opts, :cycle)
    expected = Keyword.fetch!(opts, :value)
    actual   = Waveform.at(waves, signal, cycle)

    if actual != expected do
      meta = waves.signals[signal]
      raise ExUnit.AssertionError,
        left:    actual,
        right:   expected,
        message: """
        Waveform signal mismatch at cycle #{cycle}
          signal:   #{signal}
          expected: #{format_val(expected, meta)}
          actual:   #{format_val(actual, meta)}
        """
    end

    :ok
  end

  @doc """
  Assert a signal sequence starting at a given cycle.

      assert_sequence waves, :rx_state, [0, 1, 2, 1, 0], from: 0
  """
  @spec assert_sequence(Waveform.t(), atom(), [integer()], keyword()) :: :ok
  def assert_sequence(%Waveform{} = waves, signal, expected_seq, opts \\ []) do
    Waveform.assert_sequence(waves, signal, expected_seq, opts)
  end

  @doc """
  Assert a signal is stable (unchanged) across a cycle range.

      assert_stable waves, :valid, during: 5..10
      assert_stable waves, :valid, value: 1, during: 5..10
  """
  @spec assert_stable(Waveform.t(), atom(), keyword()) :: :ok
  def assert_stable(%Waveform{} = waves, signal, opts) do
    Waveform.assert_stable(waves, signal, opts)
  end

  @doc """
  Assert a signal reaches a target value by a given cycle.

      assert_reaches waves, :done, 1, by: 20
  """
  @spec assert_reaches(Waveform.t(), atom(), integer(), keyword()) :: :ok
  def assert_reaches(%Waveform{} = waves, signal, target, opts \\ []) do
    Waveform.assert_reaches(waves, signal, target, opts)
  end

  # ---------------------------------------------------------------------------
  # Build helpers
  # ---------------------------------------------------------------------------

  @doc """
  Build a schedule from a design module.

  Convenience for test setup:

      schedule = Hw.Waveform.ExUnit.build_schedule(MyCounter)
  """
  @spec build_schedule(module()) :: Hw.Sim.Schedule.t()
  def build_schedule(design_module) do
    design = Hw.Compile.Elaborate.elaborate(design_module)
    Hw.Sim.Schedule.build(design)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp normalise(str) do
    str
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp waveform_diff_message(actual, expected) do
    actual_lines   = String.split(actual, "\n")
    expected_lines = String.split(expected, "\n")

    diff_lines =
      Enum.zip([expected_lines, actual_lines])
      |> Enum.with_index()
      |> Enum.filter(fn {{e, a}, _i} -> e != a end)
      |> Enum.map(fn {{e, a}, i} ->
        "  line #{i + 1}:\n    expected: #{inspect(e)}\n    actual:   #{inspect(a)}"
      end)

    extra_expected = Enum.drop(expected_lines, length(actual_lines))
    extra_actual   = Enum.drop(actual_lines, length(expected_lines))

    extra =
      cond do
        extra_expected != [] ->
          "  expected #{length(extra_expected)} more line(s):\n" <>
            Enum.map_join(extra_expected, "\n", &"    #{inspect(&1)}")
        extra_actual != [] ->
          "  got #{length(extra_actual)} extra line(s):\n" <>
            Enum.map_join(extra_actual, "\n", &"    #{inspect(&1)}")
        true ->
          ""
      end

    msg = ["Waveform mismatch:" | diff_lines] ++ [extra]
    Enum.reject(msg, &(&1 == "")) |> Enum.join("\n")
  end

  defp format_val(nil, _),                          do: "nil"
  defp format_val(v, %{hint: {:enum, m}}),           do: Map.get(m, v, Integer.to_string(v))
  defp format_val(v, %{hint: :hex}),                 do: "0x" <> Integer.to_string(v, 16)
  defp format_val(v, _),                             do: Integer.to_string(v)
end
