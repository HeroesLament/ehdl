defmodule Hw.Trace.Scope do
  @moduledoc """
  Resolves a flat signal name into a hierarchical `{scope_path, leaf}` address
  for the unified `Hw.Trace`.

  This is the piece that makes the latent scope hierarchy in the schedule
  explicit. Today the simulator partitions ops into entities by signal-name
  *prefix* (`sie_`, `cdc_`, `phy_`, …) — that prefix convention is a scope tree
  hiding inside flat names. Here we turn `:sie_rx_state` into `{[:sie], :rx_state}`
  and `:led` into `{[:top], :led}`.

  ## Source of truth

  Scope is derived from the canonical prefix table that also drives entity
  partitioning, plus the CDC-ownership override. We deliberately read these from
  `Hw.Sim.Schedule` rather than duplicating the list, so scope and simulation
  entity assignment can never drift.

    * `Hw.Sim.Schedule.instance_prefixes/0` — `[{prefix, entity, domain}]`
    * `Hw.Sim.Schedule.cdc_owned_signals/0` — signals named after SIE/top wiring
      but owned by the CDC entity (notably `dev_addr`). These MUST be checked
      first, or `dev_addr` resolves to `:_top_` (wrong scope).

  The design doc (`docs/TRACE_UNIFICATION.md`, §7 Q2) flags that this should
  eventually be IR-derived from elaboration metadata; the prefix table is the
  interim source and is what unblocks non-USB protocols when made data-driven.
  """

  @top_scope :top

  @typedoc "Ordered list of scope atoms from root, e.g. `[:sie]` or `[:top]`."
  @type scope_path :: [atom()]

  @typedoc "A hierarchical signal address."
  @type address :: {scope_path(), atom()}

  @doc """
  Resolve a flat signal name into `{scope_path, leaf}`.

  Entity-prefixed names map their prefix to a scope segment and strip it from the
  leaf; the CDC-ownership override wins over prefix matching; everything else
  lands in the top scope under its own name.

      iex> Hw.Trace.Scope.resolve(:sie_rx_state)
      {[:sie], :rx_state}
      iex> Hw.Trace.Scope.resolve(:dev_addr)   # cdc-owned override
      {[:cdc], :dev_addr}
      iex> Hw.Trace.Scope.resolve(:led)
      {[:top], :led}
  """
  @spec resolve(atom()) :: address()
  def resolve(name) when is_atom(name) do
    cond do
      name in cdc_owned() ->
        # CDC-owned signals keep their full name as the leaf: they are named
        # after SIE/top wiring (e.g. `sie_ep_in_pid`, `dev_addr`) and stripping
        # a prefix would be misleading. Scope them to :cdc, leaf unchanged.
        {[:cdc], name}

      true ->
        name_str = Atom.to_string(name)

        case Enum.find(prefixes(), fn {prefix, _entity, _domain} ->
               String.starts_with?(name_str, prefix)
             end) do
          {prefix, entity, _domain} ->
            leaf = name_str |> binary_part(byte_size(prefix), byte_size(name_str) - byte_size(prefix))
            {[entity], String.to_atom(leaf)}

          nil ->
            {[@top_scope], name}
        end
    end
  end

  @doc """
  Format an address as a dotted string, e.g. `"sie.rx_state"`.
  """
  @spec to_string(address()) :: String.t()
  def to_string({path, leaf}) do
    (path ++ [leaf]) |> Enum.map_join(".", &Atom.to_string/1)
  end

  @doc """
  Parse a dotted string or atom back into an address.

  Accepts `"sie.rx_state"`, `:"sie.rx_state"`, or a bare leaf `"led"`
  (which resolves to the top scope). This is the API-boundary convenience
  that lets a user type `Hw.Trace.find_when(trace, "top.led": 0xFF)`.
  """
  @spec parse(String.t() | atom()) :: address()
  def parse(name) when is_atom(name), do: name |> Atom.to_string() |> parse()

  def parse(str) when is_binary(str) do
    case String.split(str, ".") do
      [single] -> {[@top_scope], String.to_atom(single)}
      parts ->
        {leaf, scope} = List.pop_at(parts, -1)
        {Enum.map(scope, &String.to_atom/1), String.to_atom(leaf)}
    end
  end

  @doc "The top/root scope atom."
  @spec top_scope() :: atom()
  def top_scope, do: @top_scope

  # --- schedule-backed tables (single source of truth) ----------------------

  defp prefixes, do: Hw.Sim.Schedule.instance_prefixes()
  defp cdc_owned, do: Hw.Sim.Schedule.cdc_owned_signals()
end
