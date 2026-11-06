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
          tone: atom(),
          verb: String.t() | nil,
          since: DateTime.t() | nil,
          ours: boolean(),
          note: String.t() | nil
        }

  @doc "The status of `job` at `now`."
  @spec of(map(), DateTime.t()) :: t()
  def of(job, now \\ DateTime.utc_now())

  # A job for GitHub's runners (or another pool): how it went there, in
  # the same words, with GitHub's own reason. Whose it was is a `note`
  # apart (pages show GitHub's mark, and the note on hover). Queued, not
  # Waiting: Crew isn't the one placing it.
  def of(%{classification: "not_ours"} = job, now) do
    status =
      case job.gh_state do
        "queued" ->
          since = job.queued_at || job.seen_at

          "queued"
          |> status("hero-clock-micro", "Queued · " <> format(duration(since, now)), nil, :muted)
          |> counting("Queued", since)

        _ ->
          of(%{job | classification: "ours", blocked_reason: nil}, now)
      end

    note =
      ["Not a Crew job", job.runner_name && "ran on #{job.runner_name}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    %{status | ours: false, note: note}
  end

  def of(%{classification: "unsatisfiable", unsatisfiable_reason: @fork_reason}, _now),
    do: status("refused", "hero-shield-exclamation-micro", "Refused", @fork_reason, :danger)

  def of(%{classification: "unsatisfiable"} = job, _now),
    do:
      status(
        "unsatisfiable",
        "hero-exclamation-triangle-micro",
        "Can't run",
        job.unsatisfiable_reason,
        :warning
      )

  def of(%{gh_state: "completed"} = job, _now) do
    took = duration(job.started_at, job.completed_at)

    case job.conclusion do
      "success" ->
        status("success", "hero-check-circle-micro", "Succeeded" <> in_time(took), nil, :success)

      "failure" ->
        status("failure", "hero-x-circle-micro", "Failed" <> in_time(took), nil, :danger)

      "cancelled" ->
        status("cancelled", "hero-no-symbol-micro", "Cancelled", nil, :muted)

      "skipped" ->
        status("skipped", "hero-minus-circle-micro", "Skipped", nil, :muted)

      other ->
        status("completed", "hero-check-micro", "Completed", other, :muted)
    end
  end

  def of(%{gh_state: "in_progress"} = job, now),
    do:
      "running"
      |> status("dot", "Running · " <> format(duration(job.started_at, now)), nil, :running)
      |> counting("Running", job.started_at)

  def of(%{gh_state: "waiting"}, _now),
    do: status("waiting", "hero-clock-micro", "Waiting", "for an environment approval", :muted)

  def of(%{gh_state: "queued", blocked_reason: reason}, _now) when is_binary(reason),
    do: status("blocked", "hero-pause-circle-micro", "Blocked", reason, :warning)

  def of(%{gh_state: "queued"} = job, now) do
    since = job.queued_at || job.seen_at

    "queued"
    |> status(
      "hero-clock-micro",
      "Waiting · " <> format(duration(since, now)),
      Map.get(job, :wait_reason),
      :muted
    )
    |> counting("Waiting", since)
  end

  defp status(state, icon, label, reason, tone),
    do: %{
      state: state,
      icon: icon,
      label: label,
      reason: reason,
      tone: tone,
      verb: nil,
      since: nil,
      ours: true,
      note: nil
    }

  # A label that counts up from `since` ("Running · 3m 04s"): `verb` is
  # the words before the time, so a page can tick the time itself.
  defp counting(status, verb, since), do: %{status | verb: verb, since: since}

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
