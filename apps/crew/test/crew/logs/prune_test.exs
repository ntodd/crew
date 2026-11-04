defmodule Crew.Logs.PruneTest do
  @moduledoc "Log retention (§9.4): 30 days, and a total cap, oldest first; a live VM's log stays."
  use Crew.DataCase
  use Oban.Testing, repo: Crew.Repo

  alias Crew.Logs
  alias Crew.Logs.Prune

  setup do
    dir = Path.join(System.tmp_dir!(), "crew-prune-#{System.unique_integer([:positive])}")
    Application.put_env(:crew, :log_dir, dir)
    on_exit(fn -> Application.delete_env(:crew, :log_dir) && File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp log_dir(kind, id, bytes, days_old) do
    path = Logs.path(kind, id)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :binary.copy("x", bytes))
    Logs.put_segment(kind, id, 1, 1, 0, bytes)
    at = System.os_time(:second) - days_old * 86_400
    {{y, m, d}, {hh, mm, ss}} = :calendar.system_time_to_universal_time(at, :second)
    File.touch!(path, {{y, m, d}, {hh, mm, ss}})
    File.touch!(Path.dirname(path), {{y, m, d}, {hh, mm, ss}})
    path
  end

  defp live_vm do
    repo = repo_fixture()
    box = box_fixture()
    id = CrewProtocol.uuid7()

    Repo.insert!(%Crew.VMs.VM{
      id: id,
      box_id: box.id,
      name: CrewProtocol.Names.runner_name("abcd", box.name, id),
      repo_id: repo.id,
      class_key: ["crew-m"],
      class_hash: Crew.VMs.VM.class_hash(["crew-m"]),
      size_id: Repo.get_by!(Crew.Sizes.Size, name: "m").id,
      vcpus: 4,
      memory_mib: 8192,
      disk_gib: 60,
      state: "busy",
      deadline: DateTime.add(DateTime.utc_now(), 3600),
      requested_at: DateTime.utc_now()
    })

    id
  end

  defp segments(id),
    do:
      Repo.aggregate(from(s in "log_segments", where: s.owner_id == ^Ecto.UUID.dump!(id)), :count)

  test "logs older than the retention go, with their segments; newer ones and live VMs' stay" do
    old_job = CrewProtocol.uuid7()
    new_job = CrewProtocol.uuid7()
    old_vm = CrewProtocol.uuid7()
    live = live_vm()
    log_dir(:job, old_job, 10, 31)
    log_dir(:job, new_job, 10, 1)
    log_dir(:vm, old_vm, 10, 40)
    log_dir(:vm, live, 10, 40)

    assert :ok = perform_job(Prune, %{})
    refute File.exists?(Logs.path(:job, old_job))
    refute File.exists?(Logs.path(:vm, old_vm))
    assert File.exists?(Logs.path(:job, new_job))
    assert File.exists?(Logs.path(:vm, live))
    assert segments(old_job) == 0
    assert segments(new_job) == 1
  end

  test "a pruned log reports no lines, so nothing asks for them" do
    old_vm = CrewProtocol.uuid7()
    log_dir(:vm, old_vm, 10, 40)
    assert :ok = perform_job(Prune, %{})
    assert Logs.last_n(:vm, old_vm) == nil
    assert Logs.last_n(:job, old_vm) == nil
  end

  test "active logs count toward the cap, though they're never deleted" do
    Application.put_env(:crew, :log_max_bytes, 25)
    on_exit(fn -> Application.delete_env(:crew, :log_max_bytes) end)
    live = live_vm()
    old = CrewProtocol.uuid7()
    log_dir(:vm, live, 20, 1)
    log_dir(:job, old, 10, 2)

    assert :ok = perform_job(Prune, %{})
    assert File.exists?(Logs.path(:vm, live))
    refute File.exists?(Logs.path(:job, old))
  end

  test "past the total cap, the oldest go first" do
    Application.put_env(:crew, :log_max_bytes, 25)
    on_exit(fn -> Application.delete_env(:crew, :log_max_bytes) end)
    a = CrewProtocol.uuid7()
    b = CrewProtocol.uuid7()
    c = CrewProtocol.uuid7()
    log_dir(:job, a, 10, 3)
    log_dir(:job, b, 10, 2)
    log_dir(:job, c, 10, 1)

    assert :ok = perform_job(Prune, %{})
    refute File.exists?(Logs.path(:job, a))
    assert File.exists?(Logs.path(:job, b))
    assert File.exists?(Logs.path(:job, c))
  end
end
