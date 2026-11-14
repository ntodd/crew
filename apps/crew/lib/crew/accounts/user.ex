defmodule Crew.Accounts.User do
  @moduledoc "A person who signs in with GitHub."
  use Crew.Schema

  @roles ~w(admin member)

  schema "users" do
    field :github_id, :integer
    field :login, :string
    field :name, :string
    field :avatar_url, :string
    field :role, :string, default: "member"
    field :access_token, Crew.Encrypted.Binary, redact: true
    field :access_token_expires_at, :utc_datetime_usec
    field :refresh_token, Crew.Encrypted.Binary, redact: true
    field :refresh_token_expires_at, :utc_datetime_usec
    field :github_login_expired, :boolean, default: false
    field :access_checked_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    timestamps()
  end

  def github_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :github_id,
      :login,
      :name,
      :avatar_url,
      :access_token,
      :access_token_expires_at,
      :refresh_token,
      :refresh_token_expires_at,
      :github_login_expired
    ])
    |> validate_required([:login])
    |> unique_constraint(:login)
    |> unique_constraint(:github_id)
  end

  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role, :disabled_at])
    |> validate_inclusion(:role, @roles)
  end
end
