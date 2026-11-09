defmodule Crew.Schedules.Schedule do
  @moduledoc """
  A workflow Crew starts on a cron, with `workflow_dispatch` (§7.6).

  `cron` is GitHub's grammar: five fields, UTC. `last_due_at` is the
  schedule's clock, the latest cron minute accounted for. It starts at
  creation, so the first fire is the next match, not one that has passed.
  """
  use Crew.Schema

  alias Oban.Cron.Expression

  schema "schedules" do
    belongs_to :repo, Crew.Repos.Repo
    field :workflow, :string
    field :ref, :string
    field :cron, :string
    field :enabled, :boolean, default: true
    field :last_due_at, :utc_datetime_usec
    field :last_dispatched_at, :utc_datetime_usec
    field :last_error, :string
    timestamps()
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:workflow, :ref, :cron, :enabled])
    |> update_change(:workflow, &trim/1)
    |> update_change(:ref, &trim/1)
    |> update_change(:cron, &squeeze/1)
    |> validate_required([:workflow, :ref, :cron])
    |> validate_format(:workflow, ~r/\A[\w.-]+\.ya?ml\z/,
      message: "is the file's name in .github/workflows, like ci.yml"
    )
    |> validate_format(:ref, ~r/\A\S+\z/, message: "is a branch or tag name, without spaces")
    |> validate_length(:ref, max: 255)
    |> validate_change(:cron, fn :cron, cron ->
      case parse(cron) do
        {:ok, _} -> []
        :error -> [cron: "should be five fields: minute hour day month weekday, in UTC"]
      end
    end)
    |> unique_constraint(:cron,
      name: :schedules_repo_id_workflow_ref_cron_index,
      message: "is already scheduled for this workflow and ref"
    )
  end

  @doc "Parses GitHub's cron grammar: five fields, no `@daily` and no seconds."
  @spec parse(String.t()) :: {:ok, Expression.t()} | :error
  def parse(cron) when is_binary(cron) do
    with 5 <- length(String.split(cron)), {:ok, expr} <- Expression.parse(cron) do
      {:ok, expr}
    else
      _ -> :error
    end
  end

  @doc "The parsed cron of a schedule that passed validation."
  def expression!(%__MODULE__{cron: cron}) do
    {:ok, expr} = parse(cron)
    expr
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)

  defp squeeze(nil), do: nil
  defp squeeze(value), do: value |> String.split() |> Enum.join(" ")
end
