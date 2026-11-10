defmodule Crew.Repo.Migrations.CreateSizingDismissals do
  use Ecto.Migration

  # Right-sizing hints an admin has decided against (§7.5), keyed on the
  # job, the shape it runs on and the kind of hint, so a new size or a
  # new kind brings the hint back. A repo's go with it. The login is kept
  # for the record if the user goes.
  def change do
    create table(:sizing_dismissals) do
      add :repo_id, references(:repos, on_delete: :delete_all), null: false
      add :workflow_name, :text, null: false
      add :job_name, :text, null: false
      add :vcpus, :integer, null: false
      add :memory_mib, :integer, null: false
      add :kind, :string, null: false
      add :reason, :text
      add :user_id, references(:users, on_delete: :nilify_all)
      add :user_login, :string
      timestamps()
    end

    create unique_index(:sizing_dismissals, [
             :repo_id,
             :workflow_name,
             :job_name,
             :vcpus,
             :memory_mib,
             :kind
           ])
  end
end
