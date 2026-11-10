defmodule Crew.Sizing.Dismissal do
  @moduledoc """
  A right-sizing hint an admin decided against (§7.5): the repo, workflow
  and job name, the shape the job ran on and the kind of hint, with who
  dismissed it and why. A hint of another kind, or for another shape,
  isn't dismissed.
  """
  use Crew.Schema

  schema "sizing_dismissals" do
    belongs_to :repo, Crew.Repos.Repo
    # "" when GitHub gave none.
    field :workflow_name, :string
    field :job_name, :string
    field :vcpus, :integer
    field :memory_mib, :integer
    field :kind, :string
    field :reason, :string
    belongs_to :user, Crew.Accounts.User
    field :user_login, :string
    timestamps()
  end

  @kinds ~w(larger faster smaller custom)

  @doc "The key a hint and its dismissal share."
  def key(repo_id, workflow_name, job_name, %{vcpus: vcpus, memory_mib: memory}, kind),
    do: {repo_id, workflow_name || "", job_name || "", vcpus, memory, to_string(kind)}

  def key(%__MODULE__{} = d),
    do: {d.repo_id, d.workflow_name, d.job_name, d.vcpus, d.memory_mib, d.kind}

  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, [:reason])
    |> update_change(:reason, &blank_to_nil/1)
    |> validate_length(:reason, max: 500)
    |> validate_inclusion(:kind, @kinds)
  end

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
