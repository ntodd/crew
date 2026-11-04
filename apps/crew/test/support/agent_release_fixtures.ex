defmodule Crew.AgentReleaseFixtures do
  @moduledoc """
  Signed agent and cache tarballs for tests (§20.1), named and laid out
  as CI publishes them: `crew-<component>-<version>-<target>.tar.gz`,
  each with its `.sha256` and `.sig`. The tarballs are tiny but real:
  the agent's has `bin/crew_agent`, `bin/crew-vmctl` and `etc/nft.conf`,
  the cache's `bin/crew_cache`.
  """

  @doc "A .tar.gz of `{path, contents}` entries, every file 0755."
  def tarball(entries) do
    dir = Path.join(System.tmp_dir!(), "crew-tar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      for {path, contents} <- entries do
        full = Path.join(dir, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, contents)
        File.chmod!(full, 0o755)
      end

      out = dir <> ".tar.gz"

      :ok =
        :erl_tar.create(
          String.to_charlist(out),
          for(
            {path, _} <- entries,
            do: {String.to_charlist(path), String.to_charlist(Path.join(dir, path))}
          ),
          [:compressed]
        )

      bytes = File.read!(out)
      File.rm!(out)
      bytes
    after
      File.rm_rf!(dir)
    end
  end

  def agent_entries(version) do
    [
      {"bin/crew_agent", "#!/bin/sh\necho crew_agent #{version}\n"},
      {"bin/crew-vmctl", "#!/bin/sh\necho crew-vmctl #{version}\n"},
      {"etc/nft.conf", "table inet crew {}\n"}
    ]
  end

  def cache_entries(version), do: [{"bin/crew_cache", "#!/bin/sh\necho crew_cache #{version}\n"}]

  @doc """
  Writes a release's tarballs into `dir`, signed with `key` (see
  `Crew.ImageFixtures.keypair/0`). `components` defaults to both.
  Returns `%{component => %{file, path, sha256, signature}}`.
  """
  def write_release(dir, key, version, target, opts \\ []) do
    File.mkdir_p!(dir)

    for component <- Keyword.get(opts, :components, ["agent", "cache"]), into: %{} do
      bytes =
        tarball(if component == "agent", do: agent_entries(version), else: cache_entries(version))

      file = "crew-#{component}-#{version}-#{target}.tar.gz"
      sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      signature = CrewProtocol.Auth.sign_release(version, target, sha, key.private)

      File.write!(Path.join(dir, file), bytes)
      File.write!(Path.join(dir, file <> ".sha256"), "#{sha}  #{file}\n")
      File.write!(Path.join(dir, file <> ".sig"), signature)

      {component,
       %{file: file, path: Path.join(dir, file), sha256: sha, signature: signature, bytes: bytes}}
    end
  end

  def tmp_dir(name) do
    dir = Path.join(System.tmp_dir!(), "crew-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
