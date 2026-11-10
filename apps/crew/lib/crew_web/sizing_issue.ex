defmodule CrewWeb.SizingIssue do
  @moduledoc """
  A GitHub issue for a right-sizing hint (§7.5): a title, a Markdown body,
  and GitHub's new-issue link with both filled in. Whoever files it reads
  it on GitHub first and files it as themselves, so the App needs no
  permission for issues (§6.1).
  """
  use CrewWeb, :verified_routes

  alias Crew.Sizing.Rules.Hint
  alias CrewWeb.{GitHub, SizingComponents}

  @doc """
  The issue for `entry`: a hint with its `repo`, `workflow_name`, job
  `name`, `workflow_path` and newest run (`job`), as `Crew.Sizing` gives
  them. Nil for a hint without a size to move to: a custom one (the size
  doesn't exist yet), a larger one when no allowed size is larger, and
  fits. `crew_url` is where the body's link to the job points.
  """
  def for_hint(entry, crew_url \\ Crew.Config.base_url())

  def for_hint(%{hint: %Hint{kind: kind, to: %{name: name}}} = entry, crew_url)
      when kind in [:smaller, :larger, :faster] and is_binary(name) do
    title =
      "Move #{entry.workflow_name} · #{entry.name} to #{SizingComponents.label(entry.hint.to, entry.job)}"

    body = body(entry, crew_url)
    %{title: title, body: body, url: GitHub.new_issue_url(entry.repo, title, body)}
  end

  def for_hint(_entry, _crew_url), do: nil

  @doc "Each of `entries` with its `issue` (or nil), reading Crew's URL once."
  def put_issues(entries, crew_url \\ Crew.Config.base_url()),
    do: Enum.map(entries, &Map.put(&1, :issue, for_hint(&1, crew_url)))

  @doc "An issue as Markdown to paste elsewhere: the title as a heading, then the body."
  def markdown(%{title: title, body: body}), do: "# #{title}\n\n#{body}"

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

  @check "Once the change lands, the job's page on Crew shows its median time on each size, " <>
           "to check the new one didn't slow it down"

  # The job's page only opens once Crew has its run attempt.
  defp check(%{run_attempt_id: id} = job, crew_url) when not is_nil(id),
    do:
      "#{@check}: " <>
        crew_url <>
        ~p"/runs/#{job.github_run_id}/attempts/#{job.run_attempt}/jobs/#{job.github_id}"

  defp check(_job, _crew_url), do: @check <> "."

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
end
