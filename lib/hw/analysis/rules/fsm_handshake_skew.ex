defmodule Hw.Analysis.Rules.FsmHandshakeSkew do
  @moduledoc """
  Detects ready/valid handshake signals mis-driven from an `fsm` block.

  ## Background

  `fsm` emits **registered** outputs. A statement in a state body therefore
  describes the value latched at the end of the cycle — the value the output
  carries during the *next* cycle — even though it reads as "the value while in
  this state":

      :idle ->
        ready = 1        # reads as: ready is 1 while idle
                         # means:    ready will be 1 one cycle from now

  For a Moore-style status output the two readings differ only at transitions,
  and nobody notices. Handshake protocols live entirely at transitions, so for
  ready/valid this one-cycle skew is the difference between working and hanging
  the far side of the bus. Both defects below were found in shipped EHDL
  components, so this is not a theoretical concern.

  ## D1 — stale assert (`:fsm_handshake_skew`)

  An output asserted in a state body and *not* reassigned in the branch that
  transitions away stays asserted for the first cycle of the destination state:

      :idle ->
        arready = 1
        on arvalid do          # arready still 1 for one cycle of :resp
          next :resp           # a back-to-back master gets a second address
        end                    # accepted that is never answered

  Emitted Verilog makes it obvious once you look — the giveaway is a mux with
  identical arms, `assign _mux_66 = valid ? 1'd1 : 1'd1;`.

  Fix: deassert inside the `on` block.

      :idle ->
        arready = 1
        on arready and arvalid do
          arready = 0
          next :resp
        end

  ## D2 — single-sided handshake (`:fsm_handshake_single_sided`)

  Because outputs are registered, a ready/valid this FSM drives is *low* during
  the first cycle of the state that asserts it. A transition that tests only the
  far side therefore fires on a beat the peer never saw accepted:

      :idle ->
        ready = 1
        on valid do            # ready may still be 0 here
          load_frame(data)     # peer holds valid, believing it was not taken;
          next :sending        # we consumed it anyway -> a dropped beat
        end

  Fix: test both halves, which is what the AXI spec means by a handshake.

      on ready and valid do ... end

  ## Scope

  Only signals whose names end in `ready` or `valid`, and only ones this
  component declares as outputs. Non-handshake outputs skew too, but that is
  usually benign (and often intended) for status flags, so flagging them here
  would drown the signal.

  Transitions are found through `if` branches (both `on cond do ... end` and
  the short `on cond, next: :state` form lower to these) *and* through
  `hdl_case` clause bodies, which are a first-class place to command a state
  change. For an `hdl_case` the subject expression is treated as the guard,
  since that is what the transition is discriminating on.

  Severity follows the direction of the skew:

  - held **asserted** into the next state — `:error`. The peer can complete a
    handshake that is never served, and it hangs.
  - held **deasserted** into the next state — `:warning`. Costs one cycle of
    throughput; cannot violate the protocol.
  - single-sided transition (D2) — `:error`. Silently drops a beat.

  ## Priority

  Runs at priority 62, alongside the other FSM and register checks.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.Diagnostic

  @impl Hw.Analysis.Rule
  def priority, do: 62

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, &check_component/1)
  end

  defp check_component(comp) do
    outputs =
      (Map.get(comp, :signals) || [])
      |> Enum.filter(&(Map.get(&1, :direction) == :output))
      |> Map.new(&{&1.name, Map.get(&1, :source_location)})

    Enum.flat_map(Map.get(comp, :fsms) || [], &check_fsm(&1, outputs, comp))
  end

  defp check_fsm(fsm, outputs, comp) do
    clauses =
      case Map.get(fsm, :case_body) do
        %{clauses: cs} when is_list(cs) -> cs
        _ -> []
      end

    defaults = const_assigns(Map.get(fsm, :defaults) || [])
    bodies = Map.new(clauses, &{state_of(&1.pattern), &1.body})

    Enum.flat_map(clauses, fn clause ->
      state = state_of(clause.pattern)
      asserted = const_assigns(clause.body)
      transitions = collect_transitions(clause.body, fsm.name, [], MapSet.new(), true)

      for {sig, val} <- asserted,
          Map.has_key?(outputs, sig),
          handshake?(sig),
          t <- transitions,
          diag <- stale(sig, val, t, state, bodies, defaults, fsm, comp, outputs) ++
                  single_sided(sig, val, t, state, fsm, comp, outputs) do
        diag
      end
    end)
  end

  # D1: asserted in the state body, not reassigned on the way out, and the
  # destination drives it differently -> it holds the old value for a cycle.
  defp stale(sig, val, t, state, bodies, defaults, fsm, comp, outputs) do
    dest_val =
      case Map.fetch(const_assigns(Map.get(bodies, t.dest) || []), sig) do
        {:ok, v} -> v
        :error -> Map.get(defaults, sig)
      end

    if not MapSet.member?(t.deasserted, sig) and is_integer(dest_val) and dest_val != val do
      common =
        "handshake output `#{inspect(sig)}` is assigned #{val} in state #{inspect(state)} of " <>
          "fsm `#{inspect(fsm.name)}` but is not reassigned in the branch that transitions to " <>
          "#{inspect(t.dest)}. `fsm` outputs are registered, so it stays #{val} for the first " <>
          "cycle of #{inspect(t.dest)} (which drives it #{dest_val}). " <>
          "Add `#{sig} = #{dest_val}` inside the `on` block that transitions."

      # Direction matters. Held-asserted is a protocol violation: the peer sees
      # a ready/valid it can handshake against, and that beat is never served.
      # Held-deasserted only delays the next beat by a cycle — real, worth
      # knowing, but it cannot hang anyone.
      if val != 0 do
        [
          Diagnostic.error(
            :fsm_handshake_skew,
            common <> " Held ASSERTED into the next state, so a peer can complete a second " <>
              "handshake that is never answered.",
            Map.get(outputs, sig),
            context: %{signal: sig, module: Map.get(comp, :module), fsm: fsm.name, state: state}
          )
        ]
      else
        [
          Diagnostic.warning(
            :fsm_handshake_skew,
            common <> " Held DEASSERTED into the next state, which costs one cycle of " <>
              "throughput but cannot violate the protocol.",
            Map.get(outputs, sig),
            context: %{signal: sig, module: Map.get(comp, :module), fsm: fsm.name, state: state}
          )
        ]
      end
    else
      []
    end
  end

  # D2: the transition guard tests the peer's half but not our own registered
  # half, so it can fire on a cycle where we never actually asserted ready/valid.
  # Only meaningful while we are actually offering the handshake. In a state
  # that drives our half low we are not accepting anything, so a transition
  # guarded on the peer alone (e.g. `on not valid` while ready = 0, waiting for
  # the peer to drop) is correct and must not be flagged.
  defp single_sided(_sig, 0, _t, _state, _fsm, _comp, _outputs), do: []

  defp single_sided(sig, _val, t, state, fsm, comp, outputs) do
    refs = Enum.reduce(t.guards, MapSet.new(), &MapSet.union(signals_in(&1), &2))

    case pair_of(sig) do
      {:ok, peer} ->
        if MapSet.member?(refs, peer) and not MapSet.member?(refs, sig) do
          [
            Diagnostic.error(
              :fsm_handshake_single_sided,
              "transition out of state #{inspect(state)} in fsm `#{inspect(fsm.name)}` tests " <>
                "`#{inspect(peer)}` but not `#{inspect(sig)}`. `fsm` outputs are registered, so " <>
                "`#{inspect(sig)}` is still low on the first cycle of #{inspect(state)} — the " <>
                "transition can fire on a beat the peer does not consider accepted, silently " <>
                "dropping it. Test both halves: `on #{sig} and #{peer} do ... end`.",
              Map.get(outputs, sig),
              context: %{signal: sig, module: Map.get(comp, :module), fsm: fsm.name, state: state}
            )
          ]
        else
          []
        end

      :none ->
        []
    end
  end

  # Walk a state body collecting every transition, along with the guard chain
  # that reaches it and every signal reassigned along that branch path.
  # `top?` distinguishes the state body itself (whose assigns are the state's
  # assertion) from nested branch bodies (whose assigns are deassertions).
  defp collect_transitions(stmts, fsm_name, guards, deasserted, top?) do
    stmts = stmts || []

    level =
      if top? do
        MapSet.new()
      else
        stmts
        |> Enum.flat_map(fn
          %{type: :assign, target: t} -> [t]
          _ -> []
        end)
        |> MapSet.new()
      end

    acc = MapSet.union(deasserted, level)

    Enum.flat_map(stmts, fn
      %{type: :assign, value: {:state, dest}, target: ^fsm_name} ->
        [%{dest: dest, guards: guards, deasserted: acc}]

      %{type: :if, condition: cond, then_body: tb, else_body: eb} ->
        collect_transitions(tb, fsm_name, [cond | guards], acc, false) ++
          collect_transitions(eb, fsm_name, guards, acc, false)

      # `hdl_case` is a first-class way to command a state change, so its
      # clause bodies must be walked exactly like `if` branches. The subject
      # expression names the signals being discriminated on, which makes it
      # the guard for D2: an hdl_case over `tx_valid` that never mentions
      # `tx_ready` is a single-sided handshake just as much as `on tx_valid`.
      %{type: :case, expr: expr, clauses: cs} ->
        Enum.flat_map(cs || [], fn cl ->
          collect_transitions(Map.get(cl, :body), fsm_name, [expr | guards], acc, false)
        end)

      _ ->
        []
    end)
  end

  defp const_assigns(stmts) do
    (stmts || [])
    |> Enum.flat_map(fn
      %{type: :assign, value: {:const, v}, target: t} -> [{t, v}]
      _ -> []
    end)
    |> Map.new()
  end

  defp signals_in({:signal, name}), do: MapSet.new([name])

  defp signals_in(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> signals_in()

  defp signals_in(l) when is_list(l),
    do: Enum.reduce(l, MapSet.new(), &MapSet.union(signals_in(&1), &2))

  defp signals_in(_), do: MapSet.new()

  defp state_of({:state, s}), do: s
  defp state_of(other), do: other

  defp handshake?(name) do
    s = Atom.to_string(name)
    String.ends_with?(s, "ready") or String.ends_with?(s, "valid")
  end

  defp pair_of(name) do
    s = Atom.to_string(name)

    cond do
      String.ends_with?(s, "ready") ->
        {:ok, String.to_atom(String.replace_suffix(s, "ready", "valid"))}

      String.ends_with?(s, "valid") ->
        {:ok, String.to_atom(String.replace_suffix(s, "valid", "ready"))}

      true ->
        :none
    end
  end
end
