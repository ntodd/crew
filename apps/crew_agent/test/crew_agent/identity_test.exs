defmodule CrewAgent.IdentityTest do
  use ExUnit.Case, async: true

  alias CrewAgent.Identity

  @moduletag :tmp_dir

  defp identity, do: %Identity{agent_id: "agent-1", private_key: :crypto.strong_rand_bytes(32)}

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # On a Mac, crew-vzd (_crewvm, group crewvm) runs crew-vz from
  # agent/current/bin, so the installer makes agent/ 0750. Enrolling
  # mustn't take that away: a 0700 agent/ is "Missing executable" to
  # launchd, and the box never verifies its firewall.
  test "saving keeps the installer's mode on agent/", %{tmp_dir: tmp} do
    agent_dir = Path.join(tmp, "agent")
    File.mkdir_p!(agent_dir)
    File.chmod!(agent_dir, 0o750)

    :ok = Identity.save(agent_dir, identity())

    assert mode(agent_dir) == 0o750
    assert mode(Path.join(agent_dir, "identity.json")) == 0o600
  end

  test "an agent/ it makes is its own alone", %{tmp_dir: tmp} do
    agent_dir = Path.join(tmp, "agent")

    :ok = Identity.save(agent_dir, identity())

    assert mode(agent_dir) == 0o700
    assert {:ok, %Identity{agent_id: "agent-1"}} = Identity.load(agent_dir)
  end
end
