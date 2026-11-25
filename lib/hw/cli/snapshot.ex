defmodule Hw.CLI.Snapshot do
  @moduledoc """
  `ehdl snapshot`: a filtered source tarball of the current directory.

  Leaves out VCS, editor and build directories, Rust target output, compiled
  native libraries, crash dumps, generated design build outputs, nested
  archives and macOS metadata.

      ehdl snapshot
      ehdl snapshot --no-svg
      ehdl snapshot -o /tmp/my_snapshot.tar.gz
  """

  use Cheer.Command

  @excluded_patterns [
    ".git",
    "./.git",
    ".elixir_ls",
    "./.elixir_ls",
    ".lexical",
    "./.lexical",
    "_build",
    "./_build",
    "deps",
    "./deps",
    "cover",
    "./cover",
    "doc",
    "./doc",
    "tmp",
    "./tmp",
    "native/hw_sim_nif/target",
    "./native/hw_sim_nif/target",
    "priv/native",
    "./priv/native",
    "erl_crash.dump",
    "./erl_crash.dump",
    "*.dump",
    "*.ez",
    "*.so",
    "*.dylib",
    "*.tar.gz",
    "*.tgz",
    "._*",
    ".DS_Store",
    "designs/*/build/*.v",
    "designs/*/build/*.json",
    "designs/*/build/*.config",
    "designs/*/build/*.bit"
  ]

  command "snapshot" do
    about "Write a filtered source tarball of this directory"

    option :out, short: :o, value_name: "FILE", help: "Output file [default: ~/ehdl_snapshot_<time>.tar.gz]"
    option :svg, type: :boolean, default: true, help: "Include SVG files (--no-svg to leave them out)"
  end

  @impl Cheer.Command
  def run(args, _raw) do
    output = args[:out] || default_output_path()
    excludes = if args.svg, do: @excluded_patterns, else: ["*.svg" | @excluded_patterns]

    File.mkdir_p!(Path.dirname(output))

    tar_args = ["-czf", output] ++ Enum.map(excludes, &"--exclude=#{&1}") ++ ["."]

    case System.cmd("tar", tar_args, env: [{"COPYFILE_DISABLE", "1"}], stderr_to_stdout: true) do
      {_text, 0} ->
        IO.puts("#{output} (#{human_size(File.stat!(output).size)})")
        :ok

      {text, status} ->
        Hw.CLI.fail!("tar failed with status #{status}\n#{text}")
    end
  end

  defp default_output_path do
    home = System.user_home!()
    ts = timestamp()
    Path.join(home, "ehdl_snapshot_#{ts}.tar.gz")
  end

  defp timestamp do
    {{y, mo, d}, {h, mi, s}} = :calendar.local_time()

    [
      pad4(y),
      pad2(mo),
      pad2(d),
      "_",
      pad2(h),
      pad2(mi),
      pad2(s)
    ]
    |> IO.iodata_to_binary()
  end

  defp pad2(n), do: :io_lib.format("~2..0B", [n]) |> IO.iodata_to_binary()
  defp pad4(n), do: :io_lib.format("~4..0B", [n]) |> IO.iodata_to_binary()

  defp human_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp human_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp human_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 2)} MB"
end
