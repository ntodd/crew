defmodule Crew.Logs.IndexTest do
  @moduledoc "What the viewer needs before it has the lines: step starts, groups, annotations (§17.6)."
  use ExUnit.Case, async: true

  alias Crew.Logs.Index

  defp line(n, text, step \\ "s1"), do: %{n: n, t: n, step_ref: step, text: text}

  test "each step's first line" do
    index =
      Index.new()
      |> Index.add([line(1, "a"), line(2, "b"), line(3, "c", "s2")])
      |> Index.add([line(4, "d", "s2"), line(5, "e", "s3"), line(6, "f", nil)])

    assert index.steps == %{"s1" => 1, "s2" => 3, "s3" => 5}
  end

  test "groups, ::group:: and ##[group], to the matching end, across batches" do
    index =
      Index.new()
      |> Index.add([line(1, "::group::Install"), line(2, "x"), line(3, "::endgroup::")])
      |> Index.add([line(4, "##[group]Build"), line(5, "y")])

    assert Index.groups(index) == [[1, 3, "Install"], [4, nil, "Build"]]

    index = Index.add(index, [line(6, "##[endgroup]")])
    assert Index.groups(index) == [[1, 3, "Install"], [4, 6, "Build"]]
  end

  test "a new group closes an open one (the runner doesn't nest them)" do
    index =
      Index.add(Index.new(), [
        line(1, "::group::A"),
        line(2, "::group::B"),
        line(3, "::endgroup::")
      ])

    assert Index.groups(index) == [[1, 1, "A"], [2, 3, "B"]]
  end

  test "annotations, with ANSI and the runner's prefix stripped, capped" do
    index =
      Index.add(Index.new(), [
        line(1, "\e[31m::error file=lib/a.ex,line=12::boom\e[0m"),
        line(2, "##[warning]careful"),
        line(3, "::notice::fyi"),
        line(4, "not ::error:: at the start")
      ])

    assert index.annotations == [
             %{n: 1, level: "error", text: "boom", file: "lib/a.ex", line: 12},
             %{n: 2, level: "warning", text: "careful", file: nil, line: nil},
             %{n: 3, level: "notice", text: "fyi", file: nil, line: nil}
           ]

    many = for n <- 1..2000, do: line(n, "::error::e#{n}")
    assert length(Index.add(Index.new(), many).annotations) == 1000
  end

  test "group recording stops at the cap and closes the last retained group" do
    many = for n <- 1..2000, do: line(n, "::group::g#{n}")
    index = Enum.reduce(Enum.chunk_every(many, 100), Index.new(), &Index.add(&2, &1))
    saved = Jason.decode!(Index.encode(index))
    assert length(saved["groups"]) == 1000
    assert hd(saved["groups"]) == [1, 1, "g1"]
    assert List.last(saved["groups"]) == [1000, 1000, "g1000"]
    assert saved["open"] == nil
  end

  test "an oversized index from an earlier release keeps its first groups when reopened" do
    groups = for n <- 1..1001, do: [n, if(n < 1001, do: n), "group"]
    old = Jason.encode!(%{groups: groups, open: 1001})

    saved =
      old
      |> Index.decode()
      |> Index.add([line(1002, "::endgroup::")])
      |> Index.encode()
      |> Jason.decode!()

    assert saved["groups"] == Enum.take(groups, 1000)
    assert saved["open"] == nil
  end

  test "round-trips through JSON" do
    index = Index.add(Index.new(), [line(1, "::group::A"), line(2, "::error::x", "s2")])
    assert index |> Index.encode() |> Index.decode() == index
  end
end
