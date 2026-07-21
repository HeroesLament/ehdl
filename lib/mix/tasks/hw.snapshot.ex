defmodule Mix.Tasks.Hw.Snapshot do
  use Mix.Task

  @shortdoc "Create a filtered source snapshot tar.gz for EHDL"

  @moduledoc """
  Creates a filtered source snapshot tarball for the current project.

  Output file:
      ~/ehdl_snapshot_YYYYMMDD_HHMMSS.tar.gz

  Excludes:
    - VCS/editor/build artifacts
    - Rust NIF target outputs
    - compiled native libs
    - crash dumps
    - generated design build outputs
    - nested archives
    - macOS metadata files
    - optionally large SVGs via --no-svg

  Usage:
      mix hw.snapshot
      mix hw.snapshot --no-svg
      mix hw.snapshot --output /tmp/my_snapshot.tar.gz
  """

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

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          no_svg: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    output = opts[:output] || default_output_path()
    include_svg? = !opts[:no_svg]

    excludes =
      if include_svg? do
        @excluded_patterns
      else
        ["*.svg" | @excluded_patterns]
      end

    File.mkdir_p!(Path.dirname(output))

    env = [{"COPYFILE_DISABLE", "1"}]

    tar_args =
      ["-czf", output] ++
        Enum.flat_map(excludes, fn pattern -> ["--exclude=#{pattern}"] end) ++
        ["."]

    Mix.shell().info("Creating snapshot:")
    Mix.shell().info("  #{output}")

    case System.cmd("tar", tar_args,
           env: env,
           stderr_to_stdout: true
         ) do
      {output_text, 0} ->
        size =
          case File.stat(output) do
            {:ok, stat} -> human_size(stat.size)
            _ -> "unknown size"
          end

        Mix.shell().info(output_text |> String.trim())
        Mix.shell().info("Done: #{output} (#{size})")

      {output_text, status} ->
        Mix.raise("""
        tar failed with status #{status}

        #{output_text}
        """)
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
