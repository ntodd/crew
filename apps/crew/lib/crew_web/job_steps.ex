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
          conclusion: String.t() | nil
        }

  @doc "The steps of `job`, given the guest's (`Crew.Logs.steps/1`), in order."
  @spec of(map(), [map()]) :: [step()]
  def of(job, guest) do
    api = for s <- job.steps || [], is_integer(s["number"]), do: from_api(s)

    guest =
      for g <- guest || [],
          is_integer(g[:number]),
          do: Map.take(g, ~w(number name status conclusion)a)

    steps =
      cond do
        job.gh_state == "in_progress" and guest != [] -> guest
        api != [] -> api
        true -> guest
      end

    Enum.sort_by(steps, & &1.number)
  end

  defp from_api(s),
    do: %{number: s["number"], name: s["name"], status: s["status"], conclusion: s["conclusion"]}

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
    %{
      done: Enum.count(steps, &(&1.status == "completed")),
      total: length(steps),
      current: Enum.find_value(steps, &(&1.status == "in_progress" && &1.name)),
      failed: Enum.find_value(steps, &(state(&1) == "failure" && &1.name))
    }
  end
end
