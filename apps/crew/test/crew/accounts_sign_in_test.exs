defmodule Crew.AccountsSignInTest do
  # Who gets which account at sign-in, and losing access when that changes.
  use Crew.DataCase

  alias Crew.{Accounts, Scope}

  defp sign_in(id, login, config, opts \\ []) do
    Accounts.sign_in_from_github(
      %{"id" => id, "login" => login, "name" => login, "avatar_url" => nil},
      %{access_token: "ghu_#{id}", refresh_token: "ghr_#{id}"},
      Keyword.merge([config: config], opts)
    )
  end

  describe "identity" do
    test "a new GitHub account that takes a renamed user's old login gets a new account" do
      alice = user_fixture(login: "alice", github_id: 100, role: "admin")
      config = %{admins: ["root"], allowed_users: ["alice"], allowed_org: nil}

      assert {:ok, user} = sign_in(200, "alice", config)
      refute user.id == alice.id
      assert user.role == "member"
      assert user.login == "alice"

      # The old record keeps its GitHub id and gets its login back when its
      # owner signs in under the new name.
      stale = Repo.reload!(alice)
      assert stale.github_id == 100
      refute stale.login == "alice"

      config = %{config | allowed_users: ["alice", "alice-renamed"]}
      assert {:ok, renamed} = sign_in(100, "alice-renamed", config)
      assert renamed.id == alice.id
      assert renamed.login == "alice-renamed"
      assert renamed.role == "admin"
    end

    test "a record without a GitHub id is claimed by login" do
      user = user_fixture(login: "carol", github_id: nil)
      config = %{admins: [], allowed_users: ["carol"], allowed_org: nil}

      assert {:ok, signed_in} = sign_in(300, "carol", config)
      assert signed_in.id == user.id
      assert signed_in.github_id == 300
    end
  end

  describe "who may sign in" do
    test "an admin no longer configured or in the org is refused" do
      user_fixture(login: "bob", github_id: 300, role: "admin")
      config = %{admins: ["root"], allowed_users: [], allowed_org: "acme"}

      assert {:error, :not_allowed} = sign_in(300, "bob", config, org_member?: false)
    end

    test "an admin promoted in the UI still signs in while they're in the org" do
      user_fixture(login: "dana", github_id: 400, role: "admin")
      config = %{admins: ["root"], allowed_users: [], allowed_org: "acme"}

      assert {:ok, %{role: "admin"}} = sign_in(400, "dana", config, org_member?: true)
    end

    test "a first-claim admin keeps signing in after an allowlist is set without CREW_ADMINS" do
      config = %{admins: [], allowed_users: [], allowed_org: nil}
      assert {:ok, %{role: "admin"} = owner} = sign_in(700, "owner", config)

      config = %{config | allowed_users: ["friend"]}
      assert {:ok, signed_in} = sign_in(700, "owner", config)
      assert signed_in.id == owner.id
      assert signed_in.role == "admin"
    end

    test "an admin promoted in the UI signs in without CREW_ADMINS or an org" do
      user_fixture(login: "gail", github_id: 800, role: "admin")
      config = %{admins: [], allowed_users: ["friend"], allowed_org: nil}

      assert {:ok, %{role: "admin"}} = sign_in(800, "gail", config)
    end

    test "with an org configured, an admin promoted in the UI has to stay in it" do
      user_fixture(login: "gil", github_id: 810, role: "admin")
      config = %{admins: [], allowed_users: [], allowed_org: "acme"}

      assert {:ok, %{role: "admin"}} = sign_in(810, "gil", config, org_member?: true)
      assert {:error, :not_allowed} = sign_in(810, "gil", config, org_member?: false)

      assert Accounts.access(Repo.get_by!(Crew.Accounts.User, login: "gil"), config) ==
               :ask_org
    end

    test "with CREW_ADMINS set, an admin dropped from it and the org is refused" do
      user_fixture(login: "hank", github_id: 900, role: "admin")
      config = %{admins: ["root"], allowed_users: ["friend"], allowed_org: "acme"}

      assert {:error, :not_allowed} = sign_in(900, "hank", config, org_member?: false)
    end

    test "a disabled admin is refused whatever is configured" do
      user_fixture(
        login: "ivy",
        github_id: 950,
        role: "admin",
        disabled_at: DateTime.utc_now()
      )

      config = %{admins: [], allowed_users: [], allowed_org: nil}

      assert {:error, :disabled} = sign_in(950, "ivy", config)
    end

    test "with nothing configured, existing users still sign in" do
      user_fixture(login: "erin", github_id: 500, role: "admin")
      config = %{admins: [], allowed_users: [], allowed_org: nil}

      assert {:ok, _} = sign_in(500, "erin", config)
      assert {:error, :not_allowed} = sign_in(501, "stranger", config)
    end
  end

  describe "open LiveViews" do
    setup do
      admin = user_fixture(role: "admin")
      user = user_fixture()
      CrewWeb.Endpoint.subscribe("user_sessions:#{user.id}")
      %{admin: admin, user: user}
    end

    test "are disconnected when the user is disabled", %{admin: admin, user: user} do
      {:ok, _} = Accounts.set_disabled(Scope.for_user(admin), user, true)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "are disconnected when the user's role changes", %{admin: admin, user: user} do
      {:ok, _} = Accounts.set_role(Scope.for_user(admin), user, "admin")
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end
end
