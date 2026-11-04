defmodule Mix.Tasks.CrewImage.Smoke do
  @shortdoc "Boots the built guest image through crew-vz (macOS)"
  @moduledoc """
  Boots the built guest image on this Mac as a vz box would, with a fake
  guest API (see `CrewImage.Smoke`), and reports what happened.

      mix crew_image.smoke --crew-vz native/crew-vz/bin/crew-vz \\
        --kernel images/guest/out/arm64/kernel/Image \\
        --rootfs images/guest/out/arm64/rootfs.ext4 \\
        [--vcpus 4] [--memory-mib 4096] [--disk-gib 20] [--runner-wait-s 45] [--keep]

  Exits non-zero if a boot fails its checks; its VM directories are kept.
  """
  use Mix.Task

  @switches [
    crew_vz: :string,
    kernel: :string,
    rootfs: :string,
    vcpus: :integer,
    memory_mib: :integer,
    disk_gib: :integer,
    runner_wait_s: :integer,
    keep: :boolean
  ]

  @impl true
  def run(args) do
    {opts, []} = OptionParser.parse!(args, strict: @switches)

    for key <- [:crew_vz, :kernel, :rootfs],
        !opts[key],
        do:
          Mix.raise("crew_image.smoke: --#{String.replace(to_string(key), "_", "-")} is required")

    {:ok, _} = Application.ensure_all_started(:bandit)
    report = CrewImage.Smoke.run(opts)

    for r <- report.results, do: print(r)
    Mix.shell().info("\nsmoke: #{if report.ok, do: "PASS", else: "FAIL"} (#{report.data})")
    unless report.ok, do: exit({:shutdown, 1})
  end

  defp print(r) do
    info("\n== #{r.kind} boot: #{if r.ok, do: "ok", else: "FAILED"}")
    info("  start verb returned in #{r.start_ms} ms")
    if r.payload_ms, do: info("  payload fetched #{r.payload_ms} ms after start")
    print_marks(r)
    if r.stop_ms, do: info("  power button to power-off: #{r.stop_ms} ms")
    info("  exit: #{inspect(r.exit)}")
    for s <- r.states, do: info("  state: #{s.state} #{s.detail}")
    for l <- r.guest_logs, do: info("  guest log: #{l}")
    print_runner(r.runner_lines)
    for p <- r.problems, do: info("  PROBLEM: #{p}")
  end

  defp print_marks(r) do
    for {name, t} <- Enum.sort_by(r.marks, fn {_, t} -> if is_number(t), do: t, else: 1.0e9 end),
        t != nil do
      host = if ms = r.host_seen[name], do: ", seen #{ms} ms after start", else: ""
      info("  guest uptime #{format(t)}#{host}: #{name}")
    end
  end

  defp print_runner([]), do: :ok

  defp print_runner(lines) do
    info("  the runner printed:")
    for l <- Enum.take(lines, 40), do: info("    #{l}")
  end

  defp info(line), do: Mix.shell().info(line)

  defp format(t) when is_float(t), do: :erlang.float_to_binary(t, decimals: 3) <> " s"
  defp format(t), do: inspect(t)
end
