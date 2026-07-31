#!/usr/bin/env elixir
# frames_poke_cli.exs -- command line for FramesPoke.
#
#   mix run scripts/frames_poke_cli.exs in.frames out.frames TILE set 29_101 clear 28_116
#   mix run scripts/frames_poke_cli.exs in.frames out.frames TILE set 29_1081..1567
#   mix run scripts/frames_poke_cli.exs --show TILE
#
# Separate from frames_poke.exs so that `Code.require_file` on the module can
# never execute the CLI. The previous arrangement guarded it with
# `if System.argv() != []`, which is wrong the moment any OTHER script that
# requires the module is itself invoked with arguments -- as the SING-tile
# check was, printing a spurious usage banner mid-run.

Code.require_file(Path.join(__DIR__, "frames_poke.exs"))

grid =
  (System.get_env("PRJXRAY_DB") || Path.expand("~/src/openxc7/prjxray-db")) <>
    "/zynq7/xc7z020/tilegrid.json"

case System.argv() do
  ["--show", tile] ->
    i = FramesPoke.tile_info(tile, grid)

    IO.puts("""
    #{tile}
      baseaddr  0x#{Integer.to_string(i.baseaddr, 16)}
      frames    #{i.frames}   (minors 0..#{i.frames - 1})
      offset    #{i.offset}
      words     #{i.words}
      bit space #{i.frames * i.words * 32} bits total, #{i.words * 32} per minor\
    #{if i.alias, do: "\n  alias     -> #{i.alias["type"]} #{inspect(i.alias["sites"])}", else: ""}
    """)

  [inp, out, tile | ops] ->
    info = FramesPoke.tile_info(tile, grid)

    list =
      ops
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn
        ["set", spec] -> FramesPoke.parse_spec(spec, 1)
        ["clear", spec] -> FramesPoke.parse_spec(spec, 0)
        other -> raise "bad op #{inspect(other)}"
      end)

    inp
    |> FramesPoke.load()
    |> FramesPoke.poke_all(info, list)
    |> FramesPoke.save(out)

    IO.puts("poked #{length(list)} bits in #{tile} -> #{out}")

  _ ->
    IO.puts("usage: frames_poke_cli.exs <in.frames> <out.frames> <TILE> [set|clear <minor>_<bit>]...")
    IO.puts("       frames_poke_cli.exs --show <TILE>")
end
