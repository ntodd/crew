defmodule Crew.Usage.GitHubSpend do
  @moduledoc """
  Estimates the cost of running Crew's finished jobs for the same duration on
  GitHub-hosted Linux VMs. Rates are in thousandths of a US dollar (mills).
  """

  @rates_as_of ~D[2026-11-27]
  # {vCPUs, RAM in GiB, mills per minute}. Sources:
  # https://docs.github.com/en/billing/reference/actions-runner-pricing
  # https://docs.github.com/en/actions/reference/runners/larger-runners
  # https://docs.github.com/en/actions/reference/runners/github-hosted-runners
  # The one-core ubuntu-slim runner is a container. Crew jobs run in VMs.
  @tiers %{
    "x64" => [
      {2, 8, 6},
      {4, 16, 12},
      {8, 32, 22},
      {16, 64, 42},
      {32, 128, 82},
      {64, 256, 162},
      {96, 384, 252}
    ],
    "arm64" => [
      {2, 8, 5},
      {4, 16, 8},
      {8, 32, 14},
      {16, 64, 26},
      {32, 128, 50},
      {64, 208, 98}
    ]
  }

  def estimate(rows, arch_by_box, repos) do
    by_runner =
      for row <- rows, row.job_billable_min > 0, reduce: %{} do
        totals ->
          runner = match_runner(row, arch_by_box[row.box_id], repos[row.repo_id])
          Map.update(totals, runner, row.job_billable_min, &(&1 + row.job_billable_min))
      end

    {unmatched, matched} = Map.pop(by_runner, nil, 0)

    runners =
      for {{arch, cores, rate}, minutes} <- Enum.sort(matched) do
        %{arch: arch, cores: cores, rate_mills: rate, minutes: minutes, mills: rate * minutes}
      end

    %{
      rates_as_of: @rates_as_of,
      mills: Enum.sum_by(runners, & &1.mills),
      runners: runners,
      unmatched_minutes: unmatched
    }
  end

  defp match_runner(%{vcpus: cpu, memory_mib: ram}, arch, %{private: private?})
       when is_integer(cpu) and cpu > 0 and is_integer(ram) and ram > 0 and
              is_map_key(@tiers, arch) and is_boolean(private?) do
    if not private? and cpu <= 4 and ram <= 16 * 1024 do
      {arch, 4, 0}
    else
      Enum.find_value(@tiers[arch], fn {cores, gib, rate} ->
        if cpu <= cores and ram <= gib * 1024, do: {arch, cores, rate}
      end)
    end
  end

  defp match_runner(_row, _arch, _repo), do: nil
end
