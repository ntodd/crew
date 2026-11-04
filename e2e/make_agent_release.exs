# A small agent release for the browser tests (§20.1): agent and cache
# tarballs for both Linux targets, each with its .sha256 and its .sig
# signed with the development test key, laid out as the control plane's
# image carries them (CREW_AGENT_RELEASE_DIR). They hold placeholders,
# not a real agent. Run from apps/crew:
#
#   mix run --no-start ../../e2e/make_agent_release.exs <dir> [version]
[dir | rest] = System.argv()
version = List.first(rest) || "0.9.0"
root = Path.expand("..", __DIR__)

seed =
  Path.join(root, "images/guest/keys/test-signing.key")
  |> File.read!()
  |> String.split("\n")
  |> Enum.reject(&(String.starts_with?(&1, "#") or String.trim(&1) == ""))
  |> Enum.join()
  |> String.trim()
  |> Base.decode64!()

File.mkdir_p!(dir)

for target <- ["linux-amd64", "linux-arm64"], component <- ["agent", "cache"] do
  file = "crew-#{component}-#{version}-#{target}.tar.gz"
  path = Path.join(dir, file)

  entries =
    if component == "agent",
      do: [{~c"bin/crew_agent", "e2e agent\n"}, {~c"etc/nft.conf", "table inet crew {}\n"}],
      else: [{~c"bin/crew_cache", "e2e cache\n"}]

  :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
  sha = path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  File.write!(path <> ".sha256", "#{sha}  #{file}\n")
  File.write!(path <> ".sig", CrewProtocol.Auth.sign_release(version, target, sha, seed))
end
