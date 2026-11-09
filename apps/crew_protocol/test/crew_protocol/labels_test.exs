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
      assert parse(["crew"]) ==
               {:ours, %{size_id: "m", arch: :any, key: ["crew"], alias: false, spare: false}}
    end

    test "crew-<size> is that size on any arch" do
      assert parse(["crew-l"]) ==
               {:ours, %{size_id: "l", arch: :any, key: ["crew-l"], alias: false, spare: false}}
    end

    test "crew-<arch> is the default size on that arch" do
      assert parse(["crew-arm64"]) ==
               {:ours,
                %{size_id: "m", arch: :arm64, key: ["crew-arm64"], alias: false, spare: false}}

      assert parse(["crew-x64"]) ==
               {:ours, %{size_id: "m", arch: :x64, key: ["crew-x64"], alias: false, spare: false}}
    end

    test "crew-<size>-<arch> is that size and arch" do
      assert parse(["crew-xs-x64"]) ==
               {:ours,
                %{size_id: "xs", arch: :x64, key: ["crew-xs-x64"], alias: false, spare: false}}
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
               {:ours,
                %{
                  size_id: "m",
                  arch: :any,
                  key: ["crew-m", "self-hosted"],
                  alias: false,
                  spare: false
                }}

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
                %{
                  size_id: "m",
                  arch: :x64,
                  key: ["linux", "self-hosted", "x64"],
                  alias: true,
                  spare: false
                }}
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

  describe "the -spare suffix" do
    test "every form of the grammar takes it, last" do
      assert parse(["crew-spare"]) ==
               {:ours,
                %{size_id: "m", arch: :any, key: ["crew-spare"], alias: false, spare: true}}

      assert parse(["crew-l-spare"]) ==
               {:ours,
                %{size_id: "l", arch: :any, key: ["crew-l-spare"], alias: false, spare: true}}

      assert parse(["crew-arm64-spare"]) ==
               {:ours,
                %{
                  size_id: "m",
                  arch: :arm64,
                  key: ["crew-arm64-spare"],
                  alias: false,
                  spare: true
                }}

      assert parse(["crew-l-arm64-spare"]) ==
               {:ours,
                %{
                  size_id: "l",
                  arch: :arm64,
                  key: ["crew-l-arm64-spare"],
                  alias: false,
                  spare: true
                }}

      assert {:ours, %{size_id: "big-mem", arch: :x64, spare: true}} =
               parse(["crew-big-mem-x64-spare"])
    end

    test "next to generic labels" do
      assert parse(["self-hosted", "crew-l-spare", "arm64"]) ==
               {:ours,
                %{
                  size_id: "l",
                  arch: :arm64,
                  key: ["arm64", "crew-l-spare", "self-hosted"],
                  alias: false,
                  spare: true
                }}

      assert {:ours, %{size_id: "m", arch: :x64, spare: true}} =
               parse(["crew-spare", "linux", "x64"])

      assert parse(["crew-l-arm64-spare", "x64"]) == {:unsatisfiable, "contradictory arch labels"}

      assert parse(["crew-l-spare", "gpu"]) ==
               {:unsatisfiable, "crew-l-spare can't be combined with gpu"}
    end

    test "-spare before the arch says where it goes" do
      assert parse(["crew-l-spare-arm64"]) ==
               {:unsatisfiable, "-spare goes last: crew-l-arm64-spare"}

      assert parse(["crew-spare-x64"]) == {:unsatisfiable, "-spare goes last: crew-x64-spare"}
    end

    test "the size without the suffix still has to exist and be live" do
      assert parse(["crew-nope-spare"]) == {:unsatisfiable, "unknown size nope"}
      assert parse(["crew-old-spare"]) == {:unsatisfiable, "size old retired"}

      retired_l = Enum.map(@sizes, &if(&1.name == "l", do: %{&1 | retired: true}, else: &1))
      assert Labels.parse(["crew-l-spare"], retired_l, []) == {:unsatisfiable, "size l retired"}

      no_default = Enum.map(@sizes, &%{&1 | is_default: false})
      assert Labels.parse(["crew-spare"], no_default, []) == {:unsatisfiable, "no default size"}
    end

    test "a spare and a regular label are still two Crew labels" do
      assert parse(["crew-l", "crew-l-spare"]) == {:unsatisfiable, "more than one Crew label"}
    end

    test "aliases are never spare" do
      aliases = [%{labels: ["self-hosted", "spare"], size_id: "l", arch: :any}]

      assert parse(["spare", "self-hosted"], aliases) ==
               {:ours,
                %{
                  size_id: "l",
                  arch: :any,
                  key: ["self-hosted", "spare"],
                  alias: true,
                  spare: false
                }}
    end
  end

  describe "sizes whose names predate the -spare rule" do
    @colliding [
      %{id: "m", name: "m", is_default: true, retired: false},
      %{id: "l", name: "l", is_default: false, retired: false},
      %{id: "spare", name: "spare", is_default: false, retired: false},
      %{id: "big-spare", name: "big-spare", is_default: false, retired: false},
      %{id: "s-x64-spare", name: "s-x64-spare", is_default: false, retired: false},
      %{id: "l-spare", name: "l-spare", is_default: false, retired: true}
    ]

    defp parse_colliding(labels), do: Labels.parse(labels, @colliding, [])

    test "a size named spare keeps its labels, regular" do
      assert parse_colliding(["crew-spare"]) ==
               {:ours,
                %{size_id: "spare", arch: :any, key: ["crew-spare"], alias: false, spare: false}}

      assert {:ours, %{size_id: "spare", arch: :arm64, spare: false}} =
               parse_colliding(["crew-spare-arm64"])
    end

    test "a size ending in -spare keeps its label, regular" do
      assert {:ours, %{size_id: "big-spare", arch: :any, spare: false}} =
               parse_colliding(["crew-big-spare"])

      assert {:ours,
              %{size_id: "s-x64-spare", arch: :any, key: ["crew-s-x64-spare"], spare: false}} =
               parse_colliding(["crew-s-x64-spare"])
    end

    test "a retired one stays retired" do
      assert parse_colliding(["crew-l-spare"]) == {:unsatisfiable, "size l-spare retired"}
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
