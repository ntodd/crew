defmodule Crew.UsageSummaryTest do
  use Crew.DataCase

  alias Crew.{Scope, Usage}

  defp today, do: Date.utc_today()

  defp day_start(day),
    do: day |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.add(0, :microsecond)

  defp at(day, s),
    do: day |> day_start() |> DateTime.add(s) |> Map.put(:microsecond, {0, 6})

  defp admin, do: Scope.for_user(user_fixture(role: "admin"))

  defp member(repos) do
    user = user_fixture()

    for repo <- repos,
        do:
          Repo.insert!(%Crew.Repos.Access{
            user_id: user.id,
            repo_id: repo.id,
            checked_at: DateTime.utc_now()
          })

    Scope.for_user(user)
  end

  setup do
    %{repo: repo_fixture(name: "app"), other: repo_fixture(name: "api"), box: box_fixture()}
  end

  describe "summary/3" do
    test "totals, a series with every day, and breakdowns", %{repo: repo, box: box} do
      yesterday = Date.add(today(), -1)
      ran_fixture(box, repo, yesterday, 600)
      ran_fixture(box, repo, Date.add(today(), -6), 120)
      Usage.roll_up()

      s = Usage.summary(admin(), Date.add(today(), -6), today())

      assert length(s.series) == 7
      assert Enum.map(s.series, & &1.day) == Enum.map(-6..0, &Date.add(today(), &1))
      assert s.totals.job_s == 720
      assert s.totals.job_count == 2
      assert s.totals.busy_s == 720
      assert s.totals.boot_s == 60
      assert s.totals.idle_s == 60
      assert s.totals.teardown_s == 20
      assert s.totals.vm_s == 860
      assert s.pending == []

      assert [%{box: %{id: id}, vm_s: 860, job_s: 720}] = s.boxes
      assert id == box.id
      assert [%{repo: %{id: rid}, job_count: 2}] = s.repos
      assert rid == repo.id
      assert [%{shape: %{name: "m", vcpus: 4, memory_mib: 8192}, job_s: 720}] = s.shapes
    end

    test "a day reads the same live and stored", %{repo: repo, other: other, box: box} do
      yesterday = Date.add(today(), -1)
      ran_fixture(box, repo, yesterday, 600)
      ran_fixture(box, other, yesterday, 61, vcpus: 2, memory_mib: 4096)
      job_row_fixture(repo, started_at: at(yesterday, 0), completed_at: at(yesterday, 30))
      box_metric_fixture(box, DateTime.to_unix(at(yesterday, 100)))
      scope = admin()

      live = Usage.summary(scope, yesterday, yesterday)
      Usage.roll_up()
      assert Repo.aggregate(Crew.Usage.Day, :count) > 0
      assert Usage.summary(scope, yesterday, yesterday) == live
    end

    test "today is counted live", %{repo: repo, box: box} do
      vm_fixture(box,
        repo_id: repo.id,
        requested_at: DateTime.add(DateTime.utc_now(), -120),
        busy_at: DateTime.add(DateTime.utc_now(), -60)
      )

      s = Usage.summary(admin(), today(), today())
      assert s.totals.vm_count == 1
      assert s.totals.busy_s >= 59
    end

    test "older days not yet rolled up are pending, not zero", %{repo: repo, box: box} do
      ran_fixture(box, repo, Date.add(today(), -10), 600)

      s = Usage.summary(admin(), Date.add(today(), -12), today())
      assert Date.add(today(), -10) in s.pending
      # Before the first VM there's nothing to roll up.
      refute Date.add(today(), -12) in s.pending
      assert s.totals.job_s == 0
    end

    test "box use against what it offered while online", %{repo: repo, box: box} do
      yesterday = Date.add(today(), -1)
      ran_fixture(box, repo, yesterday, 600)
      t = DateTime.to_unix(at(yesterday, 0))
      for i <- 0..99, do: box_metric_fixture(box, t + i * 5)
      Usage.roll_up()

      [b] = Usage.summary(admin(), yesterday, yesterday).boxes
      cap = Crew.Scheduler.capacity(box)

      assert b.online_s == 500
      assert_in_delta b.mem_use, (8192 + 128) * 670 / (cap.memory_mib * 500), 1.0e-9
      assert_in_delta b.vcpu_use, 4 * 670 / (cap.vcpus * 500), 1.0e-9
    end

    test "box use is nil without samples", %{repo: repo, box: box} do
      yesterday = Date.add(today(), -1)
      ran_fixture(box, repo, yesterday, 600)
      assert [%{mem_use: nil, vcpu_use: nil}] = Usage.summary(admin(), yesterday, yesterday).boxes
    end

    test "a member sees every box and the fleet, and only the repos they can read", %{
      repo: repo,
      other: other,
      box: box
    } do
      yesterday = Date.add(today(), -1)
      ran_fixture(box, repo, yesterday, 600)
      ran_fixture(box, other, yesterday, 300)
      third = repo_fixture(name: "web")
      ran_fixture(box, third, yesterday, 60)

      s = Usage.summary(member([repo]), yesterday, yesterday)

      assert s.totals.job_s == 960
      assert [%{vm_s: vm_s}] = s.boxes
      assert vm_s == s.totals.vm_s
      assert [%{repo: %{id: id}, job_s: 600}, %{repo: nil, job_s: 360, job_count: 2}] = s.repos
      assert id == repo.id
    end

    test "revoked boxes and archived repos still count", %{repo: repo, box: box} do
      yesterday = Date.add(today(), -1)
      ran_fixture(box, repo, yesterday, 600)

      Repo.update_all(from(b in Crew.Boxes.Box, where: b.id == ^box.id),
        set: [revoked_at: DateTime.utc_now()]
      )

      Repo.update_all(from(r in Crew.Repos.Repo, where: r.id == ^repo.id),
        set: [archived_at: DateTime.utc_now()]
      )

      Usage.roll_up()

      s = Usage.summary(member([repo]), yesterday, yesterday)
      assert [%{box: %{revoked_at: %DateTime{}}}] = s.boxes
      assert [%{repo: %{id: id}}] = s.repos
      assert id == repo.id
    end

    test "a shape no size matches shows as itself", %{repo: repo, box: box} do
      yesterday = Date.add(today(), -1)
      ran_fixture(box, repo, yesterday, 600, vcpus: 3, memory_mib: 5000)

      assert [%{shape: %{name: nil, vcpus: 3}}] =
               Usage.summary(admin(), yesterday, yesterday).shapes
    end
  end

  describe "summary/4, for one box or repo" do
    test "a box's rows and its use only", %{repo: repo, other: other, box: box} do
      yesterday = Date.add(today(), -1)
      ran_fixture(box, repo, yesterday, 600)
      ran_fixture(box_fixture(), other, yesterday, 300)
      Usage.roll_up()

      s = Usage.summary(admin(), yesterday, yesterday, box_id: box.id)
      assert s.totals.job_s == 600
      assert [%{box: %{id: id}}] = s.boxes
      assert id == box.id
    end

    test "a box's repos, one row each, nil for the ones the viewer can't read", %{
      repo: repo,
      other: other,
      box: box
    } do
      yesterday = Date.add(today(), -1)
      ran_fixture(box, repo, yesterday, 600)
      ran_fixture(box, other, yesterday, 300)
      ran_fixture(box, repo_fixture(name: "web"), yesterday, 60)
      Usage.roll_up()

      s = Usage.summary(member([repo]), yesterday, yesterday, box_id: box.id, others: :each)

      assert [%{repo: %{}, job_s: 600}, %{repo: nil, job_s: 300}, %{repo: nil, job_s: 60}] =
               s.repos
    end

    test "a repo's rows, and nothing for a repo the viewer can't read", %{
      repo: repo,
      other: other,
      box: box
    } do
      yesterday = Date.add(today(), -1)
      ran_fixture(box, repo, yesterday, 600)
      ran_fixture(box, other, yesterday, 300)
      Usage.roll_up()

      assert Usage.summary(admin(), yesterday, yesterday, repo_id: repo.id).totals.job_s == 600

      assert Usage.summary(member([other]), yesterday, yesterday, repo_id: repo.id).totals.job_s ==
               0
    end
  end
end
