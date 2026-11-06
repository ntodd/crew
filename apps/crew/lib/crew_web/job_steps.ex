defmodule CrewWeb.JobSteps do
  @moduledoc """
  A job's steps as the run page shows them (§16.2), and how far through
  them it is. While a job runs, the guest's steps are the live ones: it
  reads them from the runner as they change, where GitHub's arrive only
  with the job's webhooks. Once it's done, GitHub's are the record.
  """

  @type step :: %{
          number: integer(),
          name: String.t() | nil,
          status: String.t() | nil,
          conclusion: String.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @doc "The steps of `job`, given the guest's (`Crew.Logs.steps/1`), in order."
  @spec of(map(), [map()]) :: [step()]
  def of(job, guest) do
    api = for s <- job.steps || [], is_integer(s["number"]), do: from_api(s)

    guest = for g <- guest || [], is_integer(g[:number]), do: from_guest(g)

    steps = if source(job, guest) == :guest, do: guest, else: api
    Enum.sort_by(steps, & &1.number)
  end

  @doc """
  Whose steps a page shows for `job`, given the guest's: the guest's
  while the job runs and it has some (they're live), else GitHub's when
  there are any, else the guest's. The run page and the job page both go
  by this, so a step's number (`#step-N`) is the same on both.
  """
  @spec source(map(), [map()]) :: :guest | :api
  def source(job, guest) do
    cond do
      job.gh_state == "in_progress" and Enum.any?(guest || [], &is_integer(&1[:number])) -> :guest
      Enum.any?(job.steps || [], &is_integer(&1["number"])) -> :api
      true -> :guest
    end
  end

  defp from_api(s) do
    %{
      number: s["number"],
      name: s["name"],
      status: s["status"],
      conclusion: s["conclusion"],
      started_at: time(s["started_at"]),
      completed_at: time(s["completed_at"])
    }
  end

  defp from_guest(g) do
    %{
      number: g.number,
      name: g[:name],
      status: g[:status],
      conclusion: g[:conclusion],
      started_at: time(g[:started_at]),
      completed_at: time(g[:completed_at])
    }
  end

  # GitHub's are ISO 8601; the guest's are Unix milliseconds.
  defp time(%DateTime{} = t), do: t

  defp time(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, t} -> t
      _ -> nil
    end
  end

  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, t, _} -> t
      _ -> nil
    end
  end

  defp time(_), do: nil

  @doc "A step's state, for its segment of the bar."
  @spec state(map()) :: String.t()
  def state(%{status: "completed", conclusion: c})
      when c in ~w(success failure cancelled skipped),
      do: c

  # Done, but nothing says how: the guest can tell a step finished (the
  # next one started) before it knows its outcome.
  def state(%{status: "completed"}), do: "done"
  def state(%{status: "in_progress"}), do: "running"
  def state(_step), do: "pending"

  @doc """
  How far through its steps a job is: how many are done of how many, the
  name of the one running, and the name of the first that failed. Nil
  when there are no steps to go by.
  """
  @spec progress([step()]) ::
          %{
            done: integer(),
            total: integer(),
            current: String.t() | nil,
            failed: String.t() | nil
          }
          | nil
  def progress([]), do: nil

  def progress(steps) do
    current = Enum.find(steps, &(&1.status == "in_progress"))
    failed = Enum.find(steps, &(state(&1) == "failure"))

    %{
      done: Enum.count(steps, &(&1.status == "completed")),
      total: length(steps),
      current: current && current.name,
      current_number: current && current.number,
      failed: failed && failed.name,
      failed_number: failed && failed.number
    }
  end

  @doc """
  What a step's segment says on hover: which step of how many, and how
  it went ("succeeded in 4s") or that it's running, `since` when, for
  the page's clock to count.
  """
  @spec describe(map(), integer()) ::
          %{title: String.t(), outcome: String.t(), since: DateTime.t() | nil}
  def describe(step, total) do
    state = state(step)
    took = took(step)

    outcome =
      case state do
        "running" ->
          "running"

        "pending" ->
          "not started"

        s when s in ~w(success failure done) and is_integer(took) ->
          "#{verb(s)} in #{CrewWeb.JobStatus.format(took)}"

        s ->
          verb(s)
      end

    %{
      title: "Step #{step.number} of #{total} · #{step[:name] || "Step #{step.number}"}",
      outcome: outcome,
      since: if(state == "running", do: step[:started_at])
    }
  end

  defp verb("success"), do: "succeeded"
  defp verb("failure"), do: "failed"
  defp verb(other), do: other

  defp took(%{started_at: %DateTime{} = from, completed_at: %DateTime{} = to}),
    do: CrewWeb.JobStatus.duration(from, to)

  defp took(_step), do: nil
end
