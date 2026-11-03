defmodule Crew.ReposTest do
  use Crew.DataCase

  alias Crew.{GitHubStub, Repos, Scope}

  setup do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    Application.put_env(:crew, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: pem
    })

    on_exit(fn -> Application.delete_env(:crew, :github_app) end)
    Crew.GitHub.InstallationTokens.clear()
    Crew.GitHub.Budget.reset()
    :ok
  end

  @installation %{
    "id" => 77,
    "account" => %{"login" => "acme", "id" => 9, "type" => "Organization"},
    "permissions" => %{
      "administration" => "write",
      "actions" => "write",
      "metadata" => "read",
      "pull_requests" => "read",
      "members" => "read"
    }
  }

  defp repo_json(id, name, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "full_name" => "acme/#{name}",
        "private" => true,
        "default_branch" => "main",
        "archived" => false
      },
      extra
    )
  end

  defp stub_sync(repos) do
    GitHubStub.stub(%{
      {"GET", "/app/installations"} => {200, [@installation]},
      {"POST", "/app/installations/77/access_tokens"} =>
        {201, %{"token" => "ghs_x", "expires_at" => "2099-01-01T00:00:00Z"}},
      {"GET", "/installation/repositories"} =>
        {200, %{"total_count" => length(repos), "repositories" => repos}}
    })
  end

  describe "sync" do
    test "creates the installation and its repos" do
      stub_sync([
        repo_json(1, "app"),
        repo_json(2, "site", %{"private" => false, "default_branch" => "trunk"})
      ])

      assert {:ok, 2} = Repos.sync_all()

      [installation] = Repos.list_installations()
      assert installation.github_id == 77
      assert installation.account_login == "acme"
      assert installation.account_type == "Organization"
      assert installation.permissions["administration"] == "write"
      assert installation.synced_at

      site = Repos.get_by_full_name("acme/site")
      assert site.private == false
      assert site.default_branch == "trunk"
      assert site.enabled
      assert site.fork_prs == "refuse"
    end

    test "is idempotent, and archives repos no longer listed" do
      stub_sync([repo_json(1, "app"), repo_json(2, "site")])
      {:ok, 2} = Repos.sync_all()

      stub_sync([repo_json(1, "app")])
      {:ok, 1} = Repos.sync_all()

      assert Repos.get_by_full_name("acme/site").archived_at
      refute Repos.get_by_full_name("acme/app").archived_at
      assert length(Repos.list()) == 1

      stub_sync([repo_json(1, "app"), repo_json(2, "site")])
      {:ok, 2} = Repos.sync_all()
      refute Repos.get_by_full_name("acme/site").archived_at
    end

    test "keeps a repo's settings across syncs, and follows renames by GitHub id" do
      stub_sync([repo_json(1, "app")])
      {:ok, 1} = Repos.sync_all()
      admin = Scope.for_user(user_fixture(role: "admin"))

      {:ok, _} =
        Repos.update_settings(admin, Repos.get_by_full_name("acme/app"), %{"priority" => "5"})

      stub_sync([repo_json(1, "renamed")])
      {:ok, 1} = Repos.sync_all()
      repo = Repos.get_by_full_name("acme/renamed")
      assert repo.priority == 5
      assert Repos.get_by_full_name("acme/app") == nil
    end

    test "GitHub's archived repos are archived here too" do
      stub_sync([repo_json(1, "app", %{"archived" => true})])
      {:ok, _} = Repos.sync_all()
      assert Repos.get_by_full_name("acme/app").archived_at
    end
  end

  describe "installation events" do
    test "deleted marks the installation removed and archives its repos" do
      stub_sync([repo_json(1, "app")])
      {:ok, 1} = Repos.sync_all()

      :ok = Repos.installation_removed(77)
      [i] = Repos.list_installations(all: true)
      assert i.removed_at
      assert Repos.get_by_full_name("acme/app").archived_at
    end

    test "suspend and unsuspend" do
      {:ok, i} = Repos.upsert_installation(@installation)
      {:ok, i} = Repos.set_suspended(i.github_id, true)
      assert i.suspended_at
      {:ok, i} = Repos.set_suspended(i.github_id, false)
      refute i.suspended_at
    end

    test "repositories added for an installation Crew hasn't seen fetch it first" do
      GitHubStub.stub(%{{"GET", "/app/installations/77"} => {200, @installation}})
      :ok = Repos.repos_added(77, [%{"id" => 4, "full_name" => "acme/early", "private" => true}])

      assert Repos.get_by_full_name("acme/early").installation_id ==
               Repos.get_installation_by_github_id(77).id
    end

    test "repositories added and removed" do
      {:ok, _} = Repos.upsert_installation(@installation)
      :ok = Repos.repos_added(77, [%{"id" => 3, "full_name" => "acme/new", "private" => true}])
      assert Repos.get_by_full_name("acme/new")
      :ok = Repos.repos_removed(77, [%{"id" => 3, "full_name" => "acme/new"}])
      assert Repos.get_by_full_name("acme/new").archived_at
    end
  end

  describe "permissions" do
    test "the installation's missing permissions" do
      {:ok, i} =
        Repos.upsert_installation(%{
          @installation
          | "permissions" => %{"actions" => "read", "metadata" => "read"}
        })

      assert Repos.missing_permissions(i) == [
               {"actions", "write"},
               {"administration", "write"},
               {"members", "read"},
               {"pull_requests", "read"}
             ]

      {:ok, i} = Repos.upsert_installation(@installation)
      assert Repos.missing_permissions(i) == []
    end
  end

  describe "settings (§7.4)" do
    setup do
      stub_sync([repo_json(1, "app")])
      {:ok, 1} = Repos.sync_all()

      %{
        repo: Repos.get_by_full_name("acme/app"),
        admin: Scope.for_user(user_fixture(role: "admin"))
      }
    end

    test "admins change them, and it's audited", %{repo: repo, admin: admin} do
      Repos.subscribe_settings()

      {:ok, repo} =
        Repos.update_settings(admin, repo, %{
          "enabled" => "false",
          "allowed_sizes" => ["s", "m"],
          "max_concurrent" => "3",
          "fork_prs" => "allow",
          "priority" => "10"
        })

      assert {repo.enabled, repo.allowed_sizes, repo.max_concurrent, repo.fork_prs, repo.priority} ==
               {false, ["s", "m"], 3, "allow", 10}

      assert_received {:repo_settings_changed, id} when id == repo.id
      assert Enum.any?(Crew.Audit.recent(), &(&1.action == "repo.settings"))
    end

    test "allowed sizes must exist; max_concurrent is positive; fork_prs is refuse or allow",
         %{repo: repo, admin: admin} do
      assert {:error, cs} = Repos.update_settings(admin, repo, %{"allowed_sizes" => ["huge"]})
      assert errors_on(cs)[:allowed_sizes]
      assert {:error, cs} = Repos.update_settings(admin, repo, %{"max_concurrent" => "0"})
      assert errors_on(cs)[:max_concurrent]
      assert {:error, cs} = Repos.update_settings(admin, repo, %{"fork_prs" => "sometimes"})
      assert errors_on(cs)[:fork_prs]
    end

    test "members can't", %{repo: repo} do
      member = Scope.for_user(user_fixture())
      assert {:error, :unauthorized} = Repos.update_settings(member, repo, %{"priority" => "1"})
    end
  end

  describe "repo access for members (§18.3)" do
    setup do
      stub_sync([repo_json(1, "app"), repo_json(2, "secret")])
      {:ok, 2} = Repos.sync_all()
      %{app: Repos.get_by_full_name("acme/app"), secret: Repos.get_by_full_name("acme/secret")}
    end

    test "comes from the user's token, per installation", %{app: app, secret: secret} do
      user = user_fixture(access_token: "ghu_member")

      GitHubStub.stub(%{
        {"GET", "/user/installations/77/repositories"} => fn conn ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ghu_member"]

          GitHubStub.json(conn, 200, %{
            "total_count" => 1,
            "repositories" => [
              Map.put(repo_json(1, "app"), "permissions", %{"pull" => true, "push" => true})
            ]
          })
        end
      })

      :ok = Repos.refresh_access(user)
      scope = Scope.for_user(user)
      assert Repos.can_read?(scope, app.id)
      refute Repos.can_read?(scope, secret.id)
      assert Repos.can_push?(scope, app.id)
      assert Repos.readable_ids(scope) == [app.id]
    end

    test "admins can read everything", %{secret: secret} do
      admin = Scope.for_user(user_fixture(role: "admin"))
      assert Repos.can_read?(admin, secret.id)
      assert Repos.readable_ids(admin) == :all
    end

    test "on an error the last result is kept for 6 hours, then lapses", %{app: app} do
      user = user_fixture()

      Repo.insert!(%Crew.Repos.Access{
        user_id: user.id,
        repo_id: app.id,
        can_push: false,
        checked_at: DateTime.add(DateTime.utc_now(), -5 * 3600)
      })

      GitHubStub.stub(%{{"GET", "/user/installations/77/repositories"} => {502, %{}}})

      assert {:error, _} = Repos.refresh_access(user)
      assert Repos.can_read?(Scope.for_user(user), app.id)

      Repo.update_all(Crew.Repos.Access,
        set: [checked_at: DateTime.add(DateTime.utc_now(), -7 * 3600)]
      )

      refute Repos.can_read?(Scope.for_user(user), app.id)
    end

    test "a refresh that drops a repo tells the user's pages", %{app: app} do
      user = user_fixture()

      Repo.insert!(%Crew.Repos.Access{
        user_id: user.id,
        repo_id: app.id,
        can_push: false,
        checked_at: DateTime.utc_now()
      })

      Phoenix.PubSub.subscribe(Crew.PubSub, "user:#{user.id}")

      GitHubStub.stub(%{
        {"GET", "/user/installations/77/repositories"} =>
          {200, %{"total_count" => 0, "repositories" => []}}
      })

      :ok = Repos.refresh_access(user)
      assert_received {:repo_access_changed, removed} when removed == [app.id]
      refute Repos.can_read?(Scope.for_user(user), app.id)
    end
  end
end
