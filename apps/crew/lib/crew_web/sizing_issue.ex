defmodule CrewWeb.SizingIssue do
  @moduledoc """
  GitHub issues for right-sizing hints (§7.5), one per hint or one per
  repo: a title, a Markdown body, and GitHub's new-issue link with both
  filled in. Whoever files one reads it on GitHub first and files it as
  themselves, so the App needs no permission for issues (§6.1).
  """
  use CrewWeb, :verified_routes

  alias Crew.Sizing.Rules.Hint
  alias CrewWeb.{GitHub, SizingComponents}

  # The longest link GitHub opens, with room to spare.
  @max_url 8000

  @check "Once the change lands, the job's page on Crew shows its median time on each size, " <>
           "to check the new one didn't slow it down"

  @doc """
  The issue for `entry`: a hint with its `repo`, `workflow_name`, job
  `name`, `workflow_path` and newest run (`job`), as `Crew.Sizing` gives
  them. Nil for a hint without a size to move to: a custom one (the size
  doesn't exist yet), a larger one when no allowed size is larger, and
  fits. `crew_url` is where the body's link to the job points.
  """
  def for_hint(entry, crew_url \\ Crew.Config.base_url()) do
    if actionable?(entry) do
      title =
        "Move #{entry.workflow_name} · #{entry.name} to #{SizingComponents.label(entry.hint.to, entry.job)}"

      body = body(entry, crew_url)
      %{title: title, body: body, url: GitHub.new_issue_url(entry.repo, title, body)}
    end
  end

  @doc """
  One issue for a repo's hints (`entries`, the most memory freed first):
  a checklist of the jobs with a size to move to, grouped by workflow
  file, or nil when none has one. With each hint's week (`freed_gib_h`,
  from `Crew.Sizing.fleet/1`), the title and the first line say what the
  changes would free or take.

  GitHub refuses a link much past 8,000 characters, so the link's body
  leaves jobs off the end and points to the repo on Crew for the rest.
  `body`, which Copy as Markdown copies, always has every job.
  """
  def for_repo(repo, entries, crew_url \\ Crew.Config.base_url()) do
    case Enum.filter(entries, &actionable?/1) do
      [] ->
        nil

      rows ->
        title = repo_title(repo, rows)
        body = repo_body(repo, rows, rows, crew_url)
        url = GitHub.new_issue_url(repo, title, body)

        url =
          if String.length(url) <= @max_url,
            do: url,
            else: fitting_url(repo, title, rows, crew_url)

        %{title: title, body: body, url: url}
    end
  end

  # The link with the most of `rows` that fits, found by halving: each
  # job only makes the link longer. With none, it still points to Crew.
  defp fitting_url(repo, title, rows, crew_url) do
    url = fn k ->
      GitHub.new_issue_url(repo, title, repo_body(repo, Enum.take(rows, k), rows, crew_url))
    end

    0
    |> bisect(length(rows) - 1, &(String.length(url.(&1)) <= @max_url))
    |> url.()
  end

  # The largest k in lo..hi that fits, taking lo to fit.
  defp bisect(lo, hi, _fits?) when lo >= hi, do: lo

  defp bisect(lo, hi, fits?) do
    mid = div(lo + hi + 1, 2)
    if fits?.(mid), do: bisect(mid, hi, fits?), else: bisect(lo, mid - 1, fits?)
  end

  @doc "Each of `entries` with its `issue` (or nil), reading Crew's URL once."
  def put_issues(entries, crew_url \\ Crew.Config.base_url()),
    do: Enum.map(entries, &Map.put(&1, :issue, for_hint(&1, crew_url)))

  @doc "An issue as Markdown to paste elsewhere: the title as a heading, then the body."
  def markdown(%{title: title, body: body}), do: "# #{title}\n\n#{body}"

  defp actionable?(%{hint: %Hint{kind: kind, to: %{name: name}}}),
    do: kind in [:smaller, :larger, :faster] and is_binary(name)

  defp actionable?(_entry), do: false

  # -- one hint ------------------------------------------------------------------

  defp body(%{hint: hint, job: job} = entry, crew_url) do
    saving = SizingComponents.saving(hint)

    [
      "Crew suggests #{more(hint.kind)} for **#{entry.workflow_name} · #{entry.name}** in #{entry.repo.full_name}.",
      change(hint, job),
      file(entry),
      "#{SizingComponents.shape(hint.from)} → #{SizingComponents.shape(hint.to)}#{saving && ", " <> saving}.",
      "#{basis(hint)}\n\n" <> Enum.map_join(hint.reasons, "\n", &"- #{&1}"),
      check(job, crew_url)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp more(:smaller), do: "a smaller size"
  defp more(:larger), do: "more memory"
  defp more(:faster), do: "more vCPUs"

  defp change(hint, job) do
    was = SizingComponents.runs_on_now(job)
    now = SizingComponents.runs_on(hint.to, job)
    lines = if was, do: ["- runs-on: #{was}", "+ runs-on: #{now}"], else: ["+ runs-on: #{now}"]
    Enum.join(["```diff" | lines] ++ ["```"], "\n")
  end

  defp file(%{repo: repo, workflow_path: path}) do
    with url when is_binary(url) <- GitHub.workflow_url(repo, path),
         do: "In [`#{GitHub.workflow_file(path)}`](#{url})."
  end

  defp basis(%Hint{runs: 1}), do: "From the last run:"
  defp basis(%Hint{runs: n}), do: "From the last #{n} runs:"

  defp check(job, crew_url) do
    case job_url(job, crew_url) do
      nil -> @check <> "."
      url -> "#{@check}: #{url}"
    end
  end

  # The job's page on Crew, which only opens once Crew has its run attempt.
  defp job_url(%{run_attempt_id: id} = job, crew_url) when not is_nil(id),
    do:
      crew_url <> ~p"/runs/#{job.github_run_id}/attempts/#{job.run_attempt}/jobs/#{job.github_id}"

  defp job_url(_job, _crew_url), do: nil

  # -- one repo ------------------------------------------------------------------

  defp repo_title(repo, rows) do
    jobs = "Right-size #{jobs(length(rows))} in #{repo.full_name}"

    case week(rows) do
      nil ->
        jobs

      {freed, taken} when freed >= taken ->
        "#{jobs}: frees #{SizingComponents.gib_h(freed - taken)} GiB-hours a week"

      {freed, taken} ->
        "#{jobs}: takes #{SizingComponents.gib_h(taken - freed)} GiB-hours a week"
    end
  end

  defp jobs(1), do: "1 job"
  defp jobs(n), do: "#{n} jobs"

  # What all `rows` would free and take over the week, when each says.
  defp week(rows) do
    if Enum.all?(rows, &is_number(&1[:freed_gib_h])) do
      weeks = Enum.map(rows, & &1.freed_gib_h)
      freed = weeks |> Enum.filter(&(&1 > 0)) |> Enum.sum()
      taken = weeks |> Enum.filter(&(&1 < 0)) |> Enum.sum()
      {freed, -taken}
    end
  end

  # The body for `rows`, the first of `all`, pointing to Crew for the rest.
  defp repo_body(repo, rows, all, crew_url) do
    left = length(all) - length(rows)

    more =
      if left > 0,
        do: "And #{left} more on Crew: " <> crew_url <> ~p"/repos/#{repo.id}",
        else:
          "Each job's page on Crew shows its median time on each size, " <>
            "to check a change didn't slow it down."

    [intro(repo, length(all), week(all)) | Enum.map(groups(rows), &group(repo, &1, crew_url))]
    |> Enum.concat([more])
    |> Enum.join("\n\n")
  end

  defp intro(repo, n, nil), do: "Crew suggests a new size for #{jobs(n)} in #{repo.full_name}."

  defp intro(repo, n, {freed, taken}),
    do:
      intro(repo, n, nil) <>
        " Over the last 7 days, the changes would have freed #{SizingComponents.gib_h(freed)} " <>
        "GiB-hours of reserved memory and taken #{SizingComponents.gib_h(taken)}."

  # The rows by workflow file (or name, without one), each group where
  # its first job comes.
  defp groups(rows) do
    by = Enum.group_by(rows, &group_key/1)
    rows |> Enum.map(&group_key/1) |> Enum.uniq() |> Enum.map(&Map.fetch!(by, &1))
  end

  defp group_key(entry) do
    case GitHub.workflow_file(entry.workflow_path) do
      nil -> {:workflow, entry.workflow_name}
      file -> {:file, file}
    end
  end

  defp group(repo, [first | _] = rows, crew_url) do
    heading =
      case GitHub.workflow_url(repo, first.workflow_path) do
        nil -> first.workflow_name || "Workflow"
        url -> "[`#{GitHub.workflow_file(first.workflow_path)}`](#{url})"
      end

    "### #{heading}\n\n" <> Enum.map_join(rows, "\n", &item(&1, crew_url))
  end

  defp item(%{hint: hint, job: job} = entry, crew_url) do
    now = "`#{SizingComponents.runs_on(hint.to, job)}`"

    change =
      case SizingComponents.runs_on_now(job) do
        nil -> now
        was -> "`#{was}` → #{now}"
      end

    link =
      case job_url(job, crew_url) do
        nil -> ""
        url -> " [On Crew](#{url})"
      end

    "- [ ] **#{entry.workflow_name} · #{entry.name}**: #{change}. #{List.first(hint.reasons)}#{link}"
  end
end
