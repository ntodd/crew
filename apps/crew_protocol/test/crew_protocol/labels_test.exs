defmodule CrewProtocol.LabelsTest do
  use ExUnit.Case, async: true

  alias CrewProtocol.Labels

  @sizes [
    %{id: "xs", name: "xs", is_default: false, retired: false},
    %{id: "s", name: "s", is_default: false, retired: false},
    %{id: "m", name: "m", is_default: true, retired: false},
    %{id: "l", name: "l", is_default: false, retired: false},
    %{id: "big-mem", name: "big-mem", is_default: false, retired: false},
    %{id: "old", name: "old", is_default: false, retired: true}
  ]

  @aliases [
    %{labels: ["linux", "self-hosted", "x64"], size_id: "m", arch: :x64},
    %{labels: ["self-hosted"], size_id: "s", arch: :any}
  ]

  defp parse(labels, aliases \\ []), do: Labels.parse(labels, @sizes, aliases)

  describe "key/1" do
    test "lowercases, deduplicates and sorts" do
      assert Labels.key(["Self-Hosted", "crew-M", "self-hosted"]) == ["crew-m", "self-hosted"]
    end
  end

  describe "the four forms of a Crew label" do
    test "crew is the default size on any arch" do
      assert parse(["crew"]) == {:ours, %{size_id: "m", arch: :any, key: ["crew"], alias: false}}
    end

    test "crew-<size> is that size on any arch" do
      assert parse(["crew-l"]) ==
               {:ours, %{size_id: "l", arch: :any, key: ["crew-l"], alias: false}}
    end

    test "crew-<arch> is the default size on that arch" do
      assert parse(["crew-arm64"]) ==
               {:ours, %{size_id: "m", arch: :arm64, key: ["crew-arm64"], alias: false}}

      assert parse(["crew-x64"]) ==
               {:ours, %{size_id: "m", arch: :x64, key: ["crew-x64"], alias: false}}
    end

    test "crew-<size>-<arch> is that size and arch" do
      assert parse(["crew-xs-x64"]) ==
               {:ours, %{size_id: "xs", arch: :x64, key: ["crew-xs-x64"], alias: false}}
    end

    test "a size name with a hyphen parses with and without an arch" do
      assert {:ours, %{size_id: "big-mem", arch: :any}} = parse(["crew-big-mem"])
      assert {:ours, %{size_id: "big-mem", arch: :arm64}} = parse(["crew-big-mem-arm64"])
    end

    test "case doesn't matter" do
      assert {:ours, %{size_id: "l", arch: :arm64, key: ["crew-l-arm64"]}} =
               parse(["CREW-L-ARM64"])
    end
  end

  describe "generic labels" do
    test "may appear next to a Crew label and are part of the key" do
      assert parse(["self-hosted", "crew-m"]) ==
               {:ours, %{size_id: "m", arch: :any, key: ["crew-m", "self-hosted"], alias: false}}

      assert {:ours, %{key: ["crew", "linux", "self-hosted"]}} =
               parse(["linux", "crew", "self-hosted"])
    end

    test "x64 or arm64 fixes the arch" do
      assert {:ours, %{arch: :arm64}} = parse(["crew-m", "arm64"])
      assert {:ours, %{arch: :x64}} = parse(["crew", "x64"])
    end

    test "an agreeing arch is fine" do
      assert {:ours, %{arch: :x64}} = parse(["crew-m-x64", "x64"])
    end

    test "duplicates are collapsed in the key" do
      assert {:ours, %{key: ["crew-m"]}} = parse(["crew-m", "Crew-M"])
    end
  end

  describe "not ours" do
    test "no Crew label" do
      assert parse(["ubuntu-latest"]) == :not_ours
      assert parse(["self-hosted", "linux", "x64"]) == :not_ours
      assert parse([]) == :not_ours
    end

    test "labels that merely contain crew aren't Crew labels" do
      assert parse(["my-crew"]) == :not_ours
      assert parse(["crewmate"]) == :not_ours
    end
  end

  describe "unsatisfiable" do
    test "more than one Crew label" do
      assert parse(["crew-m", "crew-l"]) == {:unsatisfiable, "more than one Crew label"}
    end

    test "a Crew label next to a non-generic label" do
      assert parse(["crew-m", "gpu"]) ==
               {:unsatisfiable, "crew-m can't be combined with gpu"}
    end

    test "an unknown size" do
      assert parse(["crew-huge"]) == {:unsatisfiable, "unknown size huge"}
      assert parse(["crew-huge-arm64"]) == {:unsatisfiable, "unknown size huge"}
    end

    test "a retired size" do
      assert parse(["crew-old"]) == {:unsatisfiable, "size old retired"}
    end

    test "contradictory arch labels" do
      assert parse(["crew-m-x64", "arm64"]) ==
               {:unsatisfiable, "contradictory arch labels"}

      assert parse(["crew", "x64", "arm64"]) == {:unsatisfiable, "contradictory arch labels"}
    end

    test "a bare crew- with nothing after it" do
      assert parse(["crew-"]) == {:unsatisfiable, "unknown size "}
    end

    test "no default size" do
      sizes = Enum.map(@sizes, &%{&1 | is_default: false})
      assert Labels.parse(["crew"], sizes, []) == {:unsatisfiable, "no default size"}
    end
  end

  describe "aliases" do
    test "an exact match maps to its size and arch" do
      assert parse(["self-hosted", "linux", "X64"], @aliases) ==
               {:ours,
                %{size_id: "m", arch: :x64, key: ["linux", "self-hosted", "x64"], alias: true}}
    end

    test "a subset or superset doesn't match" do
      assert parse(["self-hosted", "linux"], @aliases) == :not_ours
      assert parse(["self-hosted", "linux", "x64", "gpu"], @aliases) == :not_ours
    end

    test "an alias to a retired size is unsatisfiable" do
      aliases = [%{labels: ["legacy"], size_id: "old", arch: :any}]
      assert parse(["legacy"], aliases) == {:unsatisfiable, "size old retired"}
    end

    test "a Crew label wins over an alias" do
      aliases = [%{labels: ["crew-m"], size_id: "l", arch: :any}]
      assert {:ours, %{size_id: "m"}} = parse(["crew-m"], aliases)
    end
  end

  describe "crew_label?/1" do
    test "is crew or starts with crew-" do
      assert Labels.crew_label?("crew")
      assert Labels.crew_label?("crew-m")
      refute Labels.crew_label?("crewm")
      refute Labels.crew_label?("self-hosted")
    end
  end

  describe "parse_runs_on/1" do
    test "takes a YAML-ish runs-on value as typed in the label tester" do
      assert Labels.parse_runs_on("crew-m") == ["crew-m"]
      assert Labels.parse_runs_on("[self-hosted, crew-m]") == ["self-hosted", "crew-m"]
      assert Labels.parse_runs_on(" [ 'self-hosted', \"crew-l\" ] ") == ["self-hosted", "crew-l"]
      assert Labels.parse_runs_on("") == []
      assert Labels.parse_runs_on(~s(["self-hosted", "crew-m"])) == ["self-hosted", "crew-m"]
      assert Labels.parse_runs_on("runs-on: [ 'crew-m' ]") == ["crew-m"]
      assert Labels.parse_runs_on("runs-on:\n  - crew-m\n  - \"linux\"") == ["crew-m", "linux"]
    end
  end
end
