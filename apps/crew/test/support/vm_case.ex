defmodule Crew.VMCase do
  @moduledoc """
  Tests of VMs and the scheduler. The test process stands in for the
  box's agent: it registers as the agent, so commands arrive as
  `{:dispatch, %CrewProtocol.Command{}}`. GitHub is stubbed in shared
  mode, since the VM servers call it from their own processes.
  """
  use ExUnit.CaseTemplate

  alias Crew.Repo

  using do
    quote do
      use Oban.Testing, repo: Crew.Repo

      import Ecto.Query
      import Crew.Fixtures
      import Crew.VMCase

      alias Crew.{GitHubStub, Jobs, Repo, Scheduler, VMs}
      alias Crew.VMs.{Server, VM}
    end
  end

  setup tags do
    Crew.DataCase.setup_sandbox(tags)
    Req.Test.set_req_test_to_shared(tags)
    restart_vm_supervisor()

    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    Application.put_env(:crew, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: pem
    })

    Application.put_env(:crew, :vm_timers_ms, Map.get(tags, :timers, %{}))

    on_exit(fn ->
      Application.delete_env(:crew, :github_app)
      Application.delete_env(:crew, :vm_timers_ms)
      stop_vm_servers()
    end)

    Crew.GitHub.InstallationTokens.clear()
    Crew.GitHub.Budget.reset()
    Crew.Settings.ensure_deployment_id()
    Crew.Images.register_dev_images()

    repo = Crew.Fixtures.repo_fixture(name: "app")
    box = Crew.Fixtures.box_fixture(name: "m4")
    image = Repo.get_by!(Crew.Images.Image, arch: "arm64")
    Crew.Images.put_box_state(box.id, image.id, "ready")

    %{repo: repo, box: box, image: image, inst: repo.installation.github_id}
  end

  @doc """
  A new VM supervisor, with its own restart budget: the servers earlier
  tests crashed don't count against this test's.
  """
  def restart_vm_supervisor do
    :ok = Supervisor.terminate_child(Crew.Supervisor, Crew.VMs.Supervisor)
    {:ok, _} = Supervisor.restart_child(Crew.Supervisor, Crew.VMs.Supervisor)
  end

  @doc "Stops every VM server (their timers would outlive the test's sandbox)."
  def stop_vm_servers do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Crew.VMs.Supervisor),
        is_pid(pid),
        do: DynamicSupervisor.terminate_child(Crew.VMs.Supervisor, pid)
  end

  @doc "The test process becomes `box`'s connected agent."
  def online(box) do
    {:ok, _} = Registry.register(Crew.Registry, {:agent, box.id}, %{})
    box
  end

  @doc "Waits for the next command of `type` sent to the agent."
  defmacro assert_command(type, timeout \\ 1_000) do
    quote do
      assert_receive {:dispatch, %CrewProtocol.Command{type: unquote(type)} = cmd},
                     unquote(timeout)

      cmd
    end
  end

  @doc "The routes a VM's life needs: a token, a JIT config, runner deletes."
  def github_routes(repo, opts \\ []) do
    test = self()
    inst = repo.installation.github_id
    delete_status = Keyword.get(opts, :delete_status, 204)

    %{
      {"POST", "/app/installations/#{inst}/access_tokens"} =>
        {201, %{"token" => "ghs", "expires_at" => "2099-01-01T00:00:00Z"}},
      {"POST", "/repos/#{repo.full_name}/actions/runners/generate-jitconfig"} => fn conn ->
        body = Crew.GitHubStub.body(conn)
        send(test, {:jit_requested, body})
        id = System.unique_integer([:positive])

        Crew.GitHubStub.json(conn, 201, %{
          "runner" => %{"id" => id, "name" => body["name"]},
          "encoded_jit_config" => jit_config(id, body["name"])
        })
      end,
      {"DELETE", "/repos/#{repo.full_name}/actions/runners/*"} => fn conn ->
        send(test, {:runner_deleted, conn.request_path})
        status = if is_function(delete_status), do: delete_status.(), else: delete_status
        Plug.Conn.send_resp(conn, status, if(status == 422, do: ~s({"message":"busy"}), else: ""))
      end
    }
  end

  @doc """
  A JIT config shaped like GitHub's: base64 of a JSON object of base64'd
  settings files. Like GitHub's, its `.runner` has no DisableUpdate.
  """
  def jit_config(id, name) do
    runner = Jason.encode!(%{"AgentId" => id, "AgentName" => name, "PoolId" => 1})

    %{".runner" => Base.encode64(runner), ".credentials" => Base.encode64("{}")}
    |> Jason.encode!()
    |> Base.encode64()
  end

  @doc "Polls `fun` until it returns a truthy value."
  def eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("condition not met in time")
        else
          Process.sleep(10)
          do_eventually(fun, deadline)
        end
    end
  end

  @doc """
  Waits for the VM to reach `state`, then for its server to finish the
  event that took it there. The server commits the new state before it
  runs that event's effects (the DeleteRunner job, failure accounting),
  so the row alone doesn't mean they've happened. Effects the server
  hands to another process, like the GitHub delete, still need their own
  wait.
  """
  def await_state(vm_id, state, timeout \\ 2_000) do
    vm =
      eventually(
        fn ->
          vm = Repo.get!(Crew.VMs.VM, vm_id)
          vm.state == state && vm
        end,
        timeout
      )

    settle(vm_id)
    vm
  end

  # A call returns only after the server has handled everything before it.
  # A destroyed VM's server stops itself, which settles it too.
  defp settle(vm_id) do
    if pid = Crew.VMs.Server.whereis(vm_id) do
      try do
        :sys.get_state(pid)
      catch
        :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] -> :ok
      end
    end

    :ok
  end

  @doc "A queued Crew job that's past the fork check (its run attempt is known)."
  def queued_job(repo, attrs \\ []) do
    run_id = Keyword.get(attrs, :run_id, System.unique_integer([:positive]))
    {:ok, _} = Crew.Jobs.handle_workflow_run(Crew.Fixtures.workflow_run_payload(repo, id: run_id))

    {:ok, job} =
      Crew.Jobs.handle_workflow_job(
        Crew.Fixtures.workflow_job_payload(repo, Keyword.put(attrs, :run_id, run_id))
      )

    job
  end

  @doc "Places one VM on `box` for `repo`'s `crew-m` class, as the scheduler would."
  def place(box, repo, opts \\ []) do
    size = Keyword.get_lazy(opts, :size, fn -> Repo.get_by!(Crew.Sizes.Size, name: "m") end)
    image = Repo.get_by!(Crew.Images.Image, arch: "arm64")
    key = Keyword.get(opts, :label_key, ["crew-m"])

    [vm] =
      Crew.VMs.create_placements([
        %{class: {repo.id, key}, box: box, size: size, image_id: image.id}
      ])

    vm.id
  end

  @doc "Answers the VM's `vm.start` as the agent would."
  def ack_start(box, cmd, status \\ "ok", error \\ nil) do
    payload = %{op_id: cmd.op_id, status: status, result: %{}}

    payload =
      if error, do: Map.put(payload, :error, %{code: error, message: error}), else: payload

    :ok = Crew.Operations.record_result(box.id, payload)
  end

  @doc "An agent event, as the channel would hand it over."
  def agent_event(box, type, payload) do
    {:ok, event} = CrewProtocol.Event.new(type, payload)
    Crew.Agents.handle_event(box.id, event)
  end

  @doc "Brings a placed VM to `idle`: JIT, vm.start, ack, booted, runner_listening."
  def to_idle(box, vm_id) do
    cmd = assert_command("vm.start")
    ack_start(box, cmd)
    await_state(vm_id, "starting")
    agent_event(box, "vm.state", %{"vm_id" => vm_id, "state" => "runner_listening", "at" => 1})
    await_state(vm_id, "idle")
  end

  def size_m, do: Repo.get_by!(Crew.Sizes.Size, name: "m")
end
