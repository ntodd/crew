defmodule Crew.GitHubTest do
  use Crew.DataCase

  alias Crew.{GitHub, GitHubStub}

  setup do
    Application.put_env(:crew, :github_app, %{
      app_id: "1",
      client_id: "Iv1.x",
      client_secret: "s",
      private_key: "k"
    })

    on_exit(fn -> Application.delete_env(:crew, :github_app) end)
  end

  defp refreshed(conn, test_pid) do
    send(test_pid, {:refreshed, GitHubStub.body(conn)["refresh_token"]})

    GitHubStub.json(conn, 200, %{
      "access_token" => "ghu_new",
      "refresh_token" => "ghr_new",
      "expires_in" => 28_800,
      "refresh_token_expires_in" => 15_000_000
    })
  end

  describe "user_token/1" do
    test "returns a fresh token without refreshing" do
      user = user_fixture(access_token: "ghu_fresh")
      assert {:ok, "ghu_fresh"} = GitHub.user_token(user)
    end

    test "refreshes a token about to expire and stores the new pair" do
      user =
        user_fixture(
          access_token: "ghu_old",
          access_token_expires_at: DateTime.add(DateTime.utc_now(), 60)
        )

      test_pid = self()
      GitHubStub.stub(%{{"POST", "/login/oauth/access_token"} => &refreshed(&1, test_pid)})

      assert {:ok, "ghu_new"} = GitHub.user_token(user)
      assert_received {:refreshed, refresh} when refresh == user.refresh_token
      user = Repo.reload!(user)
      assert user.refresh_token == "ghr_new"
      assert user.access_checked_at

      # The new token is fresh, so the next call doesn't refresh again.
      assert {:ok, "ghu_new"} = GitHub.user_token(user)
      refute_received {:refreshed, _}
    end

    test "concurrent refreshes spend the refresh token once" do
      user =
        user_fixture(
          access_token: "ghu_old",
          access_token_expires_at: DateTime.add(DateTime.utc_now(), 60)
        )

      test_pid = self()

      GitHubStub.stub(%{
        {"POST", "/login/oauth/access_token"} => fn conn ->
          Process.sleep(50)
          refreshed(conn, test_pid)
        end
      })

      tasks = for _ <- 1..4, do: Task.async(fn -> GitHub.user_token(user) end)

      assert Enum.all?(Task.await_many(tasks), &(&1 == {:ok, "ghu_new"}))
      assert_received {:refreshed, _}
      refute_received {:refreshed, _}
    end

    test "a rejected refresh token means signing in again" do
      user =
        user_fixture(
          access_token: "ghu_old",
          access_token_expires_at: DateTime.add(DateTime.utc_now(), 60)
        )

      GitHubStub.stub(%{
        {"POST", "/login/oauth/access_token"} => {200, %{"error" => "bad_refresh_token"}}
      })

      assert {:error, :login_expired} = GitHub.user_token(user)
      user = Repo.reload!(user)
      assert user.github_login_expired
      assert is_nil(user.refresh_token)
    end
  end

  describe "manifest/2" do
    test "is Crew's: webhooks on through Funnel, and the permissions runners need" do
      manifest = GitHub.manifest("crew.example.ts.net", "ab12")
      assert manifest["name"] == "Crew (ab12)"
      assert manifest["url"] == "https://crew.example.ts.net"
      assert manifest["hook_attributes"]["url"] == "https://crew.example.ts.net:8443/hooks/github"
      assert manifest["hook_attributes"]["active"]
      assert manifest["default_events"] == ["workflow_job", "workflow_run"]
      assert manifest["default_permissions"] == GitHub.required_permissions()
      assert manifest["request_oauth_on_install"] == false
    end
  end

  describe "complete_manifest/1" do
    test "stores the app's credentials and webhook secret, encrypted" do
      Application.delete_env(:crew, :github_app)

      GitHubStub.stub(%{
        {"POST", "/app-manifests/code123/conversions"} =>
          {201,
           %{
             "id" => 5,
             "slug" => "crew-ab12",
             "client_id" => "Iv1.new",
             "client_secret" => "sek",
             "pem" => "-----BEGIN RSA PRIVATE KEY-----",
             "webhook_secret" => "whsec",
             "html_url" => "https://github.com/apps/crew-ab12",
             "owner" => %{"login" => "ignored"}
           }}
      })

      assert {:ok, _} = GitHub.complete_manifest("code123")
      assert %{client_id: "Iv1.new", slug: "crew-ab12", webhook_secret: "whsec"} = GitHub.app()
      assert GitHub.webhook_secret() == "whsec"

      raw = Repo.one(from s in "settings", where: s.key == "github_app", select: s.value)
      refute raw =~ "sek"
      refute raw =~ "whsec"
    end

    test "a failed conversion stores nothing" do
      Application.delete_env(:crew, :github_app)

      GitHubStub.stub(%{
        {"POST", "/app-manifests/bad/conversions"} => {404, %{"message" => "Not Found"}}
      })

      assert {:error, {:http, 404, "Not Found"}} = GitHub.complete_manifest("bad")
      refute GitHub.configured?()
    end
  end

  describe "webhook_secret/0" do
    test "CREW_GITHUB_WEBHOOK_SECRET overrides a manifest-created App's stored secret" do
      Application.delete_env(:crew, :github_app)

      Crew.Settings.put("github_app", %{
        "client_id" => "a",
        "client_secret" => "b",
        "pem" => "c",
        "webhook_secret" => "old"
      })

      assert GitHub.webhook_secret() == "old"

      Application.put_env(:crew, :github_app, %{webhook_secret: "rotated"})
      assert GitHub.webhook_secret() == "rotated"
      # The rest of the App still comes from the database.
      assert GitHub.app().client_id == "a"
    end
  end

  describe "JWT" do
    test "app tokens are RS256 and verify with the app's public key" do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      jwt = Crew.GitHub.JWT.app_token("Iv1.x", pem, 1_000_000)

      [h, c, s] = String.split(jwt, ".")
      assert %{"alg" => "RS256"} = h |> Base.url_decode64!(padding: false) |> JSON.decode!()

      assert %{"iss" => "Iv1.x", "exp" => 1_000_540, "iat" => 999_940} =
               c |> Base.url_decode64!(padding: false) |> JSON.decode!()

      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key

      assert :public_key.verify(
               h <> "." <> c,
               :sha256,
               Base.url_decode64!(s, padding: false),
               {:RSAPublicKey, n, e}
             )
    end
  end
end
