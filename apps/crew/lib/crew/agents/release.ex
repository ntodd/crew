defmodule Crew.Agents.Release do
  @moduledoc """
  A signed agent or crew_cache tarball for one target (§20.1), as the
  control plane's image carries it. `path` is the file in
  CREW_AGENT_RELEASE_DIR; `signature` is `CrewProtocol.Auth.sign_release/4`'s,
  base64.
  """
  use Crew.Schema

  schema "agent_releases" do
    field :component, :string
    field :version, :string
    field :target, :string
    field :sha256, :string
    field :signature, :string
    field :size, :integer
    field :path, :string
    timestamps(updated_at: false)
  end
end
