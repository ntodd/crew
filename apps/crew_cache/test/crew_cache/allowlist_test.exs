defmodule CrewCache.AllowlistTest do
  use ExUnit.Case, async: true

  alias CrewCache.Allowlist

  describe "host_for_prefix/1" do
    test "maps Design A path prefixes to the compiled hosts" do
      assert %{host: "registry-1.docker.io", upstream: "registry-1.docker.io"} =
               Allowlist.host_for_prefix("docker.io")

      assert %{host: "ghcr.io", realm: "https://ghcr.io/token"} =
               Allowlist.host_for_prefix("ghcr.io")
    end

    test "knows only the compiled prefixes" do
      assert Allowlist.host_for_prefix("registry-1.docker.io") == nil
      assert Allowlist.host_for_prefix("evil.example") == nil
    end
  end

  describe "allowed?/3" do
    setup do
      %{
        list:
          Allowlist.compile(
            CrewProtocol.Hosts.default_allowlist() ++ ["quay.io/prometheus/node-exporter"]
          )
      }
    end

    test "matches the default entries", %{list: list} do
      assert Allowlist.allowed?(list, "registry-1.docker.io", "library/alpine")
      assert Allowlist.allowed?(list, "public.ecr.aws", "docker/library/postgres")
      assert Allowlist.allowed?(list, "ghcr.io", "actions/runner")
      assert Allowlist.allowed?(list, "mcr.microsoft.com", "dotnet/sdk")
    end

    test "a * spans path segments", %{list: list} do
      assert Allowlist.allowed?(list, "ghcr.io", "actions/runner/sub")
    end

    test "an entry without * is exact", %{list: list} do
      assert Allowlist.allowed?(list, "quay.io", "prometheus/node-exporter")
      refute Allowlist.allowed?(list, "quay.io", "prometheus/node-exporter2")
      refute Allowlist.allowed?(list, "quay.io", "prometheus/alertmanager")
    end

    test "doesn't match across hosts or outside the glob", %{list: list} do
      refute Allowlist.allowed?(list, "ghcr.io", "library/alpine")
      refute Allowlist.allowed?(list, "registry-1.docker.io", "someone/alpine")
      refute Allowlist.allowed?(list, "ghcr.io", "actions")
      refute Allowlist.allowed?(list, "ghcr.io", "actionsx/runner")
    end

    test "treats glob metacharacters other than * literally" do
      list = Allowlist.compile(["ghcr.io/a.b/*"])
      assert Allowlist.allowed?(list, "ghcr.io", "a.b/c")
      refute Allowlist.allowed?(list, "ghcr.io", "axb/c")
    end
  end

  test "valid_repo?/1 follows the distribution spec's name grammar" do
    for ok <- ["library/alpine", "a", "a-b/c_d/e.f", "a__b", "a--b/1"] do
      assert Allowlist.valid_repo?(ok), ok
    end

    for bad <- [
          "",
          "Library/alpine",
          "a//b",
          "/a",
          "a/",
          "a/../b",
          "-a",
          "a_",
          String.duplicate("a", 256)
        ] do
      refute Allowlist.valid_repo?(bad), bad
    end
  end

  test "valid_tag?/1 and digest/1" do
    assert Allowlist.valid_tag?("3.22")
    assert Allowlist.valid_tag?("latest")
    refute Allowlist.valid_tag?(".hidden")
    refute Allowlist.valid_tag?(String.duplicate("a", 129))

    hex = String.duplicate("ab", 32)
    assert Allowlist.digest("sha256:" <> hex) == {:ok, hex}
    assert Allowlist.digest("sha256:" <> String.upcase(hex)) == :error
    assert Allowlist.digest("sha512:" <> hex) == :error
    assert Allowlist.digest("latest") == :error
  end
end
