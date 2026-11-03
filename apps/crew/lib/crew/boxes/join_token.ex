defmodule Crew.Boxes.JoinToken do
  @moduledoc "A single-use, one-hour token that enrolls one box (§10.2). Only its hash is stored."
  use Crew.Schema

  schema "join_tokens" do
    field :token_hash, :binary, redact: true
    field :box_name, :string
    field :box_type, :string
    field :tailscale_auth_key, Crew.Encrypted.Binary, redact: true
    field :data_disk, :string
    field :ssh_keys, {:array, :string}, default: []
    belongs_to :created_by, Crew.Accounts.User
    belongs_to :box, Crew.Boxes.Box
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
