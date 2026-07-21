defimpl Inspect, for: Hw.Simtrace do
  def inspect(%Hw.Simtrace{sim_id: sim_id, entity_names: names, watchers: watchers}, _opts) do
    pids = Map.new(watchers, fn {k, v} -> {k, inspect(v)} end)
    "#Hw.Simtrace<sim_id=#{inspect(sim_id)}, entities=#{inspect(names)}, watchers=#{inspect(pids)}>"
  end
end
