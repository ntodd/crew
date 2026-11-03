defmodule Crew.GitHub.RunnerGCTest do
  use Crew.VMCase

  alias Crew.GitHub.RunnerGC

  defp vm_row(box, repo, state) do
    id = CrewProtocol.uuid7()
    size = size_m()

    Repo.insert!(%VM{
      id: id,
      box_id: box.id,
      name: CrewProtocol.Names.runner_name(Crew.Settings.deployment_id(), box.name, id),
      repo_id: repo.id,
      class_key: ["crew-m"],
      class_hash: VM.class_hash(["crew-m"]),
      size_id: size.id,
      vcpus: 4,
      memory_mib: 8192,
      disk_gib: 60,
      state: state,
      deadline: DateTime.add(DateTime.utc_now(), 3600),
      requested_at: DateTime.utc_now()
    })
  end

  test "deletes this deployment's runners with no VM, or a failed or destroyed one; nothing else",
       %{box: box, repo: repo} do
    Repo.update!(
      Ecto.Changeset.change(Crew.Repos.get!(repo.id), last_activity_at: DateTime.utc_now())
    )

    dep = Crew.Settings.deployment_id()
    idle = vm_row(box, repo, "idle")
    failed = vm_row(box, repo, "failed")
    destroyed = vm_row(box, repo, "destroyed")
    requested = vm_row(box, repo, "requested")

    runners = [
      %{"id" => 1, "name" => idle.name, "status" => "online", "busy" => false},
      %{"id" => 2, "name" => failed.name, "status" => "online", "busy" => false},
      %{"id" => 3, "name" => destroyed.name, "status" => "offline", "busy" => false},
      %{"id" => 4, "name" => "crew-#{dep}-m4-0123456789", "status" => "offline", "busy" => false},
      %{"id" => 5, "name" => "crew-zz99-m4-0123456789", "status" => "offline", "busy" => false},
      %{"id" => 6, "name" => "my-own-runner", "status" => "online", "busy" => false},
      %{"id" => 7, "name" => requested.name, "status" => "offline", "busy" => false}
    ]

    test = self()

    GitHubStub.stub(
      Map.merge(github_routes(repo), %{
        {"GET", "/repos/#{repo.full_name}/actions/runners"} =>
          {200, %{"total_count" => length(runners), "runners" => runners}},
        {"DELETE", "/repos/#{repo.full_name}/actions/runners/*"} => fn conn ->
          send(test, {:deleted, conn.request_path |> Path.basename() |> String.to_integer()})
          Plug.Conn.send_resp(conn, 204, "")
        end
      })
    )

    assert :ok = perform_job(RunnerGC, %{})
    deleted = for _ <- 1..3, do: assert_receive({:deleted, id}) && id
    assert Enum.sort(deleted) == [2, 3, 4]
    refute_received {:deleted, _}
  end

  test "repos without Crew activity in a day aren't listed", %{repo: repo} do
    Repo.update!(
      Ecto.Changeset.change(Crew.Repos.get!(repo.id),
        last_activity_at: DateTime.add(DateTime.utc_now(), -2 * 86_400)
      )
    )

    GitHubStub.stub(%{})
    assert :ok = perform_job(RunnerGC, %{})
  end
end
