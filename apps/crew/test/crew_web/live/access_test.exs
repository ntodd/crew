defmodule CrewWeb.AccessTest do
  # LiveViews act with the scope they mounted with, and take ids from
  # events, so both need checking.
  use CrewWeb.ConnCase

  alias Crew.{Accounts, Repo, Scope}

  describe "an open page" do
    test "reloads when its user is disabled, and can't act as them" do
      admin = user_fixture(role: "admin")
      member = user_fixture()
      {:ok, view, _} = live(log_in(build_conn(), member), ~p"/")

      {:ok, _} = Accounts.set_disabled(Scope.for_user(admin), member, true)
      assert_redirect(view, ~p"/")

      # The reload finds no session: the disabled user is signed out.
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(log_in(build_conn(), member), ~p"/")
    end

    test "reloads when its user is demoted, and loses admin powers" do
      other_admin = user_fixture(role: "admin")
      demoted = user_fixture(role: "admin")
      target = user_fixture()
      {:ok, view, _} = live(log_in(build_conn(), demoted), ~p"/admin/users")

      {:ok, _} = Accounts.set_role(Scope.for_user(other_admin), demoted, "member")
      assert_redirect(view, ~p"/admin/users")

      assert Repo.reload!(target).role == "member"
    end

    for path <- ["/", "/admin/users"] do
      test "#{path} stays up and shows the banner when the GitHub login expires" do
        user = user_fixture(role: "admin")
        {:ok, view, _} = live(log_in(build_conn(), user), unquote(path))
        refute has_element?(view, "#github-expired-banner")

        :ok = Accounts.mark_github_login_expired(user)
        Phoenix.PubSub.broadcast(Crew.PubSub, "user:#{user.id}", :github_login_expired)

        assert has_element?(view, "#github-expired-banner")
      end
    end

    test "doesn't show the banner when they signed in again before the message arrived" do
      user = user_fixture()
      {:ok, view, _} = live(log_in(build_conn(), user), ~p"/")

      :ok = Accounts.mark_github_login_expired(user)

      {:ok, _} =
        Accounts.update_tokens(Repo.reload!(user), %{access_token: "new", refresh_token: "new"})

      Phoenix.PubSub.broadcast(Crew.PubSub, "user:#{user.id}", :github_login_expired)

      refute has_element?(view, "#github-expired-banner")
    end
  end
end
