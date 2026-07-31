#!/usr/bin/env elixir
# frames_diff.exs -- compare two .frames files by CONTENT, not by formatting.
# Prints every differing (frame, word) and exits non-zero if any exist.
defmodule FD do
  def load(path) do
    path
    |> File.stream!()
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(String.trim(line), " ", parts: 2) do
        [addr, words] ->
          a = addr |> String.replace_prefix("0x", "") |> String.to_integer(16)
          w = words |> String.split(",")
              |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("0x", "") |> String.to_integer(16)))
          Map.put(acc, a, w)
        _ -> acc
      end
    end)
  end
end

[pa, pb] = System.argv()
a = FD.load(pa)
b = FD.load(pb)
zero = List.duplicate(0, 101)
keys = MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b))) |> Enum.sort()

diffs =
  for k <- keys,
      {wa, wb, i} <- Enum.zip([Map.get(a, k, zero), Map.get(b, k, zero), 0..100]) |> Enum.map(fn {x, y, i} -> {x, y, i} end),
      wa != wb,
      do: {k, i, wa, wb}

if diffs == [] do
  IO.puts("PASS: #{length(keys)} frames identical in content")
else
  IO.puts("FAIL: #{length(diffs)} differing words")
  for {k, i, wa, wb} <- Enum.take(diffs, 20) do
    IO.puts("  0x#{Integer.to_string(k, 16)} word #{i}: a=0x#{Integer.to_string(wa, 16)} c=0x#{Integer.to_string(wb, 16)} xor=0x#{Integer.to_string(Bitwise.bxor(wa, wb), 16)}")
  end
  System.halt(1)
end
