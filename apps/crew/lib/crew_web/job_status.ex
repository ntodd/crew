defmodule CrewWeb.JobStatus do
  @moduledoc """
  How a job's state reads everywhere it's shown (§17.4). Status is never
  colour alone: each one has an icon and text.
  """

  @fork_reason "fork PRs are refused on this repo"

  @type t :: %{
          state: String.t(),
          icon: String.t(),
          label: String.t(),
          reason: String.t() | nil,
          tone: atom()
        }

  @doc "The status of `job` at `now`."
  @spec of(map(), DateTime.t()) :: t()
  def of(job, now \\ DateTime.utc_now())

  def of(%{classification: "not_ours"} = job, _now) do
    status(
      "not_ours",
      "",
      "Not a Crew job",
      job.runner_name && "ran on #{job.runner_name}",
      :muted
    )
  end

  def of(%{classification: "unsatisfiable", unsatisfiable_reason: @fork_reason}, _now),
    do: status("refused", "hero-shield-exclamation", "Refused", @fork_reason, :danger)

  def of(%{classification: "unsatisfiable"} = job, _now),
    do:
      status(
        "unsatisfiable",
        "hero-exclamation-triangle",
        "Can't run",
        job.unsatisfiable_reason,
        :warning
      )

  def of(%{gh_state: "completed"} = job, _now) do
    took = duration(job.started_at, job.completed_at)

    case job.conclusion do
      "success" ->
        status("success", "hero-check-circle", "Succeeded" <> in_time(took), nil, :success)

      "failure" ->
        status("failure", "hero-x-circle", "Failed" <> in_time(took), nil, :danger)

      "cancelled" ->
        status("cancelled", "hero-no-symbol", "Cancelled", nil, :muted)

      "skipped" ->
        status("skipped", "hero-minus-circle", "Skipped", nil, :muted)

      other ->
        status("completed", "hero-check", "Completed", other, :muted)
    end
  end

  def of(%{gh_state: "in_progress"} = job, now),
    do:
      status(
        "running",
        "dot",
        "Running · " <> format(duration(job.started_at, now)),
        nil,
        :running
      )

  def of(%{gh_state: "waiting"}, _now),
    do: status("waiting", "hero-clock", "Waiting", "for an environment approval", :muted)

  def of(%{gh_state: "queued", blocked_reason: reason}, _now) when is_binary(reason),
    do: status("blocked", "hero-pause-circle", "Blocked", reason, :warning)

  def of(%{gh_state: "queued"} = job, now),
    do:
      status(
        "queued",
        "hero-clock",
        "Waiting · " <> format(duration(job.queued_at || job.seen_at, now)),
        Map.get(job, :wait_reason),
        :muted
      )

  defp status(state, icon, label, reason, tone),
    do: %{state: state, icon: icon, label: label, reason: reason, tone: tone}

  defp in_time(nil), do: ""
  defp in_time(seconds), do: " in " <> format(seconds)

  @doc "Seconds between two times, or nil."
  def duration(%DateTime{} = from, %DateTime{} = to), do: max(0, DateTime.diff(to, from))
  def duration(_from, _to), do: nil

  @doc "45s, 3m 04s, 1h 02m."
  def format(nil), do: "–"
  def format(s) when s < 60, do: "#{s}s"
  def format(s) when s < 3600, do: "#{div(s, 60)}m #{pad(rem(s, 60))}s"
  def format(s), do: "#{div(s, 3600)}h #{pad(div(rem(s, 3600), 60))}m"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "How long ago, coarsely: 12s, 4m, 3h, 2d."
  def ago(nil, _now), do: "–"

  def ago(%DateTime{} = at, now) do
    s = max(0, DateTime.diff(now, at))

    cond do
      s < 60 -> "#{s}s"
      s < 3600 -> "#{div(s, 60)}m"
      s < 86_400 -> "#{div(s, 3600)}h"
      true -> "#{div(s, 86_400)}d"
    end
  end

  @doc """
  A wait or blocked reason as a member sees it on a job in a repo they
  can't read (§18.3). The reasons are fixed text except for the stalled
  class's labels (§8.2), which can name the repo, so those go.
  """
  def masked_reason(nil), do: nil

  def masked_reason(reason) when is_binary(reason),
    do: String.replace(reason, ~r/ runners labelled \[[^\]]*\]/, " its runners")
end
