defmodule CrewWeb.SizingIssueTest do
  @moduledoc "A GitHub issue for a right-sizing hint (§7.5): its title, body and new-issue link."
  use ExUnit.Case, async: true

  alias Crew.Sizing.Rules.Hint
  alias CrewWeb.SizingIssue

  @crew "https://crew.example.ts.net"
  @repo %{id: "0193", full_name: "mona/web", default_branch: "main"}
  @m %{name: "m", vcpus: 4, memory_mib: 8192, disk_gib: 40}
  @xs %{name: "xs", vcpus: 1, memory_mib: 2048, disk_gib: 20}
  @xl %{name: "xl", vcpus: 8, memory_mib: 32_768, disk_gib: 80}

  defp entry(attrs \\ []) do
    hint =
      Keyword.get(attrs, :hint, %Hint{
        kind: :smaller,
        from: @m,
        to: @xs,
        runs: 8,
        reasons: [
          "Memory peaked at 1.1 GiB over the last 8 runs.",
          "On 1 vCPU, it would run under 1% slower, by estimate."
        ],
        saved_mib: 6144
      })

    %{
      repo: @repo,
      workflow_name: "CI",
      name: "test",
      workflow_path: Keyword.get(attrs, :workflow_path, ".github/workflows/ci.yml"),
      hint: hint,
      job: %{
        labels: Keyword.get(attrs, :labels, ["crew-m"]),
        arch: Keyword.get(attrs, :arch, "any"),
        spare: Keyword.get(attrs, :spare, false),
        run_attempt_id:
          Keyword.get(attrs, :run_attempt_id, "01a1c653-f39e-7dd3-bedb-92ca2f90acc1"),
        github_run_id: 77,
        run_attempt: 1,
        github_id: 88
      }
    }
  end

  defp query(url) do
    [_, query] = String.split(url, "?", parts: 2)
    URI.decode_query(query)
  end

  describe "for_hint/2" do
    test "a smaller size: the runs-on change, its file, the shapes, why, and where to check" do
      issue = SizingIssue.for_hint(entry(), @crew)

      assert issue.title == "Move CI · test to crew-xs"
      assert issue.body =~ "Crew suggests a smaller size for **CI · test** in mona/web."
      assert issue.body =~ "```diff\n- runs-on: crew-m\n+ runs-on: crew-xs\n```"

      assert issue.body =~
               "In [`.github/workflows/ci.yml`](https://github.com/mona/web/blob/main/.github/workflows/ci.yml)."

      assert issue.body =~ "m (4 vCPU · 8.0 GiB) → xs (1 vCPU · 2.0 GiB), frees 6.0 GiB a run."

      assert issue.body =~
               "From the last 8 runs:\n\n- Memory peaked at 1.1 GiB over the last 8 runs.\n"

      assert issue.body =~ "- On 1 vCPU, it would run under 1% slower, by estimate."
      assert issue.body =~ "#{@crew}/runs/77/attempts/1/jobs/88"
    end

    test "the link opens GitHub's new-issue form on the repo with both filled in" do
      issue = SizingIssue.for_hint(entry(), @crew)

      assert String.starts_with?(issue.url, "https://github.com/mona/web/issues/new?")
      refute issue.url =~ "+"
      assert query(issue.url) == %{"title" => issue.title, "body" => issue.body}
    end

    test "labels next to the Crew label stay, and so do its arch and tier" do
      issue =
        SizingIssue.for_hint(
          entry(labels: ["self-hosted", "crew-m-arm64-spare"], arch: "arm64", spare: true),
          @crew
        )

      assert issue.title == "Move CI · test to crew-xs-arm64-spare"

      assert issue.body =~
               "- runs-on: [self-hosted, crew-m-arm64-spare]\n+ runs-on: [self-hosted, crew-xs-arm64-spare]"
    end

    test "an arch from a generic label stays with it" do
      issue = SizingIssue.for_hint(entry(labels: ["crew-m", "x64"], arch: "x64"), @crew)
      assert issue.body =~ "- runs-on: [crew-m, x64]\n+ runs-on: [crew-xs, x64]"
    end

    test "an aliased job moves to a Crew label, keeping its alias's arch" do
      issue =
        SizingIssue.for_hint(entry(labels: ["self-hosted", "linux", "x64"], arch: "x64"), @crew)

      assert issue.body =~ "- runs-on: [self-hosted, linux, x64]\n+ runs-on: crew-xs-x64"
    end

    test "more memory and more vCPUs say so" do
      larger = %Hint{
        kind: :larger,
        from: @m,
        to: @xl,
        runs: 6,
        reasons: ["1 of the last 6 runs had a process killed for memory."],
        saved_mib: -24_576
      }

      issue = SizingIssue.for_hint(entry(hint: larger), @crew)
      assert issue.title == "Move CI · test to crew-xl"
      assert issue.body =~ "Crew suggests more memory for **CI · test** in mona/web."
      assert issue.body =~ "takes 24.0 GiB more a run."

      faster = %Hint{larger | kind: :faster, reasons: ["Its tasks waited for a CPU."]}
      assert SizingIssue.for_hint(entry(hint: faster), @crew).body =~ "Crew suggests more vCPUs"
    end

    test "without a workflow file Crew knows, the body leaves the line out" do
      issue = SizingIssue.for_hint(entry(workflow_path: "dynamic/x/y"), @crew)
      refute issue.body =~ "In ["
      refute issue.body =~ "/blob/"
    end

    test "no link to the job's page before Crew has its run attempt, which the page needs" do
      issue = SizingIssue.for_hint(entry(run_attempt_id: nil), @crew)

      assert issue.body =~
               "shows its median time on each size, to check the new one didn't slow it down."

      refute issue.body =~ @crew
    end

    test "nothing for a hint without a size to move to" do
      custom = %Hint{
        kind: :custom,
        from: @m,
        to: %{name: nil, vcpus: 4, memory_mib: 2048, disk_gib: 20},
        runs: 6,
        saved_mib: 6144
      }

      assert SizingIssue.for_hint(entry(hint: custom), @crew) == nil

      no_size = %Hint{kind: :larger, from: @xl, to: nil, runs: 1}
      assert SizingIssue.for_hint(entry(hint: no_size), @crew) == nil

      fits = %Hint{kind: :fits, from: @m, to: nil, runs: 8}
      assert SizingIssue.for_hint(entry(hint: fits), @crew) == nil
    end
  end

  describe "for_repo/3" do
    defp row(name, workflow, path, hint, extra) do
      entry(hint: hint, workflow_path: path)
      |> Map.merge(%{workflow_name: workflow, name: name})
      |> Map.merge(extra)
    end

    defp hints do
      smaller = entry().hint
      larger = %Hint{kind: :larger, from: @m, to: @xl, runs: 6, reasons: ["Killed for memory."]}
      faster = %Hint{larger | kind: :faster, reasons: ["Waits on CPUs."]}

      custom = %Hint{
        kind: :custom,
        from: @m,
        to: %{@xs | name: nil},
        runs: 6,
        reasons: ["Custom."]
      }

      [
        row("test", "CI", ".github/workflows/ci.yml", smaller, %{freed_gib_h: 7.2}),
        row("build", "CI", ".github/workflows/ci.yml", custom, %{freed_gib_h: 5.4}),
        row("integration", "Nightly", nil, faster, %{freed_gib_h: -12.0}),
        row("e2e", "CI", ".github/workflows/ci.yml", larger, %{freed_gib_h: -14.4})
      ]
    end

    test "one checklist for the repo's hints with a size to move to, by workflow file" do
      issue = SizingIssue.for_repo(@repo, hints(), @crew)

      assert issue.title == "Right-size 3 jobs in mona/web: takes 19.2 GiB-hours a week"

      assert issue.body =~
               "Crew suggests a new size for 3 jobs in mona/web. Over the last 7 days, " <>
                 "the changes would have freed 7.2 GiB-hours of reserved memory and taken 26.4."

      job = "#{@crew}/runs/77/attempts/1/jobs/88"

      assert issue.body =~
               """
               ### [`.github/workflows/ci.yml`](https://github.com/mona/web/blob/main/.github/workflows/ci.yml)

               - [ ] **CI · test**: `crew-m` → `crew-xs`. Memory peaked at 1.1 GiB over the last 8 runs. [On Crew](#{job})
               - [ ] **CI · e2e**: `crew-m` → `crew-xl`. Killed for memory. [On Crew](#{job})

               ### Nightly

               - [ ] **Nightly · integration**: `crew-m` → `crew-xl`. Waits on CPUs. [On Crew](#{job})
               """

      assert issue.body =~ "Each job's page on Crew shows its median time on each size"
      refute issue.body =~ "build"
      assert query(issue.url) == %{"title" => issue.title, "body" => issue.body}
    end

    test "without the week's numbers, the title counts the jobs" do
      rows = Enum.map(hints(), &Map.delete(&1, :freed_gib_h))
      issue = SizingIssue.for_repo(@repo, rows, @crew)

      assert issue.title == "Right-size 3 jobs in mona/web"
      refute issue.body =~ "Over the last 7 days"

      [one | _] = rows
      assert SizingIssue.for_repo(@repo, [one], @crew).title == "Right-size 1 job in mona/web"
    end

    test "what the changes free, when that's more than they take" do
      [test | _] = hints()
      assert SizingIssue.for_repo(@repo, [test], @crew).title =~ ": frees 7.2 GiB-hours a week"
    end

    test "nothing when no hint has a size to move to" do
      [_, build | _] = hints()
      assert SizingIssue.for_repo(@repo, [build], @crew) == nil
      assert SizingIssue.for_repo(@repo, [], @crew) == nil
    end

    test "a link too long for GitHub leaves jobs off the end; the Markdown keeps them all" do
      [test | _] = hints()
      long = String.duplicate("A reason that goes on. ", 6)

      rows =
        for i <- 1..120,
            do: %{test | name: "job-#{i}", hint: %{test.hint | reasons: [long]}}

      issue = SizingIssue.for_repo(@repo, rows, @crew)

      assert String.length(issue.url) <= 8000
      %{"body" => linked} = query(issue.url)
      assert linked =~ "**CI · job-1**"
      refute linked =~ "**CI · job-120**"
      assert linked =~ ~r/And \d+ more on Crew: #{@crew}\/repos\/0193\z/

      assert issue.body =~ "**CI · job-120**"
      assert SizingIssue.markdown(issue) =~ "**CI · job-120**"
    end

    test "as many jobs as fit, however many there are" do
      [test | _] = hints()
      rows = for i <- 1..2000, do: %{test | name: "job-#{i}"}
      issue = SizingIssue.for_repo(@repo, rows, @crew)

      assert String.length(issue.url) <= 8000
      %{"body" => linked} = query(issue.url)
      [_, left] = Regex.run(~r/And (\d+) more on Crew/, linked)
      shown = Regex.scan(~r/- \[ \] /, linked) |> length()
      assert shown + String.to_integer(left) == 2000

      # Close to full: one more job's line, encoded, wouldn't have fitted.
      assert String.length(issue.url) > 8000 - 400
    end
  end

  test "markdown/1: the title as a heading, then the body" do
    issue = SizingIssue.for_hint(entry(), @crew)
    assert SizingIssue.markdown(issue) == "# Move CI · test to crew-xs\n\n" <> issue.body
  end
end
