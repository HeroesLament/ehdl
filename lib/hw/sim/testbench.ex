defmodule Hw.Sim.Testbench do
  @moduledoc "Low-level testbench operations — all calls take sim_id."

  import Bitwise

  alias Hw.Sim.{State, Clock, Entity}

  @default_timeout 120_000

  # ---------------------------------------------------------------------------
  # Signal access
  # ---------------------------------------------------------------------------

  def get(signal_name, sim_id) do
    closures = Process.get({:hw_sim_closures, sim_id}) || State.top_closures(sim_id)
    widths   = Process.get({:hw_sim_widths,   sim_id}) || State.stored_signal_widths(sim_id)
    case Map.get(closures || %{}, signal_name) do
      {ops, inputs} when ops != [] ->
        env = Map.new(inputs, fn name -> {name, State.get(name, sim_id)} end)
        {_, results} = Enum.reduce(ops, {env, []}, fn op, {env, acc} ->
          outputs = Hw.Sim.Eval.eval(op, env, widths, %{})
          new_env = Enum.reduce(outputs, env, fn {k, v}, e -> Map.put(e, k, v) end)
          {new_env, acc ++ outputs}
        end)
        # Write intermediates to ETS, return the signal we actually want
        State.put_many(results, 0, sim_id)
        State.get(signal_name, sim_id)
      _ ->
        State.get(signal_name, sim_id)
    end
  end

  def set(signal_name, value, sim_id) do
    State.put(signal_name, value, 0, sim_id)
    Entity.eval_now(:_top_, sim_id)
    State.clear_top_dirty(sim_id)
  end

  def assert(signal_name, expected, sim_id) do
    actual = get(signal_name, sim_id)
    if actual != expected do
      raise """
      Signal assertion failed:
        signal:   #{inspect(signal_name)}
        expected: #{expected} (0x#{Integer.to_string(expected, 16)})
        actual:   #{actual} (0x#{Integer.to_string(actual, 16)})
      """
    end
    :ok
  end

  # ---------------------------------------------------------------------------
  # Clock control
  # ---------------------------------------------------------------------------

  def tick(clock_name, n \\ 1, sim_id) do
    flush_tick_complete(clock_name)
    Clock.tick(clock_name, n, self(), sim_id)
    receive do
      {:tick_complete, ^clock_name} -> :ok
    after
      @default_timeout ->
        raise "tick/2 timeout waiting for #{n} edges of #{clock_name}"
    end
  end

  defp flush_tick_complete(clock_name) do
    receive do
      {:tick_complete, ^clock_name} -> flush_tick_complete(clock_name)
    after
      0 -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Signal observation
  # ---------------------------------------------------------------------------

  def wait_for(signal_name, target_value, sim_id, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout, @default_timeout)
    clock      = Keyword.get(opts, :clock, :clk_48)
    max_ticks  = Keyword.get(opts, :max_ticks, 10_000)
    deadline   = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(signal_name, target_value, clock, sim_id, max_ticks, deadline)
  end

  defp do_wait(_sig, _target, _clock, _sid, 0, _deadline),
    do: {:error, :max_ticks_exceeded}
  defp do_wait(sig, target, clock, sid, ticks_left, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      tick(clock, 1, sid)
      if get(sig, sid) == target do
        :ok
      else
        do_wait(sig, target, clock, sid, ticks_left - 1, deadline)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # UART helpers
  # ---------------------------------------------------------------------------

  def uart_send(signal_name, byte, sim_id, opts \\ []) do
    clk_freq      = Keyword.get(opts, :clk_freq, 48_000_000)
    baud          = Keyword.get(opts, :baud, 115_200)
    clock         = Keyword.get(opts, :clock, :clk_48)
    ticks_per_bit = round(clk_freq / baud)

    set(signal_name, 0, sim_id)
    tick(clock, ticks_per_bit, sim_id)

    for bit <- 0..7 do
      set(signal_name, bsr(byte, bit) &&& 1, sim_id)
      tick(clock, ticks_per_bit, sim_id)
    end

    set(signal_name, 1, sim_id)
    tick(clock, ticks_per_bit, sim_id)
  end

  def uart_recv(signal_name, sim_id, opts \\ []) do
    clk_freq      = Keyword.get(opts, :clk_freq, 48_000_000)
    baud          = Keyword.get(opts, :baud, 115_200)
    clock         = Keyword.get(opts, :clock, :clk_48)
    ticks_per_bit = round(clk_freq / baud)

    case wait_for(signal_name, 0, sim_id, clock: clock) do
      {:error, reason} -> {:error, {:no_start_bit, reason}}
      :ok ->
        tick(clock, div(ticks_per_bit, 2), sim_id)
        if get(signal_name, sim_id) != 0, do: throw({:error, :start_bit_glitch})

        byte = for bit <- 0..7, reduce: 0 do
          acc ->
            tick(clock, ticks_per_bit, sim_id)
            acc ||| (get(signal_name, sim_id) <<< bit)
        end

        tick(clock, ticks_per_bit, sim_id)
        {:ok, byte}
    end
  end
end
