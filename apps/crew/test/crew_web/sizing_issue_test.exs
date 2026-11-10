defmodule CrewWeb.SizingIssueTest do
  @moduledoc "A GitHub issue for a right-sizing hint (§7.5): its title, body and new-issue link."
  use ExUnit.Case, async: true

  alias Crew.Sizing.Rules.Hint
  alias CrewWeb.SizingIssue

  @crew "https://crew.example.ts.net"
  @repo %{full_name: "mona/web", default_branch: "main"}
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

  test "markdown/1: the title as a heading, then the body" do
    issue = SizingIssue.for_hint(entry(), @crew)
    assert SizingIssue.markdown(issue) == "# Move CI · test to crew-xs\n\n" <> issue.body
  end
end
