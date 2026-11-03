defmodule Crew.GitHub do
  @moduledoc """
  The GitHub App (§6.1): its credentials, the manifest that creates it,
  sign-in through its user OAuth flow, and user tokens.

  User tokens last 8 hours; refresh tokens 6 months and are single use.
  Refreshes for a user are serialized so two can't burn the same refresh
  token, and run in their own process so a caller that dies mid-refresh
  (a closed tab) can't lose the rotated token (Foreman's).
  """

  alias Crew.{Accounts, Settings}
  alias Crew.Accounts.User
  alias Crew.GitHub.Client

  require Logger

  @refresh_margin 300

  # -- app config --------------------------------------------------------------

  @doc "The GitHub App's credentials, from the environment or the manifest flow. nil until set up."
  def app do
    env = Application.get_env(:crew, :github_app, %{})

    cond do
      present?(env[:client_id]) and present?(env[:client_secret]) and present?(env[:private_key]) ->
        env |> Map.put_new(:slug, nil) |> Map.put_new(:webhook_secret, nil)

      stored = Settings.get("github_app") ->
        %{
          app_id: stored["id"],
          slug: stored["slug"],
          client_id: stored["client_id"],
          client_secret: stored["client_secret"],
          private_key: stored["pem"],
          webhook_secret: stored["webhook_secret"],
          html_url: stored["html_url"]
        }

      true ->
        nil
    end
  end

  def configured?, do: app() != nil

  @doc "The secret GitHub signs webhook deliveries with (§6.2). nil until the app exists."
  def webhook_secret do
    case Application.get_env(:crew, :github_app, %{})[:webhook_secret] do
      secret when is_binary(secret) and secret != "" -> secret
      _ -> (app() || %{})[:webhook_secret]
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  # -- manifest flow -------------------------------------------------------------

  @doc """
  The manifest that creates this deployment's App (§6.1). Every URL is
  built from the tailnet host; webhooks come in through Tailscale Funnel
  on 8443, to the one-route hook endpoint.
  """
  def manifest(public_host, deployment_id) do
    base = "https://" <> public_host

    %{
      "name" => "Crew (#{deployment_id})",
      "url" => base,
      "hook_attributes" => %{"url" => "#{base}:8443/hooks/github", "active" => true},
      "redirect_url" => base <> "/setup/github/callback",
      "callback_urls" => [base <> "/auth/github/callback"],
      "setup_url" => base <> "/setup/github/installed",
      "public" => false,
      "request_oauth_on_install" => false,
      "default_events" => ["workflow_job", "workflow_run"],
      "default_permissions" => %{
        "administration" => "write",
        "actions" => "write",
        "metadata" => "read",
        "pull_requests" => "read",
        "members" => "read"
      }
    }
  end

  @doc "The permissions Crew asks for, and the feature each one enables (§6.1)."
  def required_permissions do
    %{
      "administration" => "write",
      "actions" => "write",
      "metadata" => "read",
      "pull_requests" => "read",
      "members" => "read"
    }
  end

  @doc "Exchanges the manifest flow's code for the new app's credentials and stores them (encrypted)."
  def complete_manifest(code) do
    with {:ok, app} <- Client.convert_manifest(code) do
      Settings.put(
        "github_app",
        Map.take(app, ~w(id slug client_id client_secret pem webhook_secret html_url))
      )

      {:ok, app}
    end
  end

  # -- sign-in -------------------------------------------------------------------

  @doc "Returns `{url, verifier}`: GitHub's authorize URL (with PKCE) and the verifier to keep in the session."
  def authorize_url(state, redirect_uri) do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    query =
      URI.encode_query(%{
        "client_id" => app().client_id,
        "redirect_uri" => redirect_uri,
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "allow_signup" => "false"
      })

    {Client.web_url() <> "/login/oauth/authorize?" <> query, verifier}
  end

  @doc "Finishes sign-in: trades the code for tokens and signs the user in."
  def complete_sign_in(code, verifier, redirect_uri) do
    app = app()
    config = Accounts.login_config()

    with {:ok, tokens} <- Client.exchange_code(app, code, verifier, redirect_uri),
         {:ok, profile} <- Client.get_user(tokens.access_token) do
      org_member? =
        config.allowed_org != nil and
          Client.org_membership(tokens.access_token, config.allowed_org) == {:ok, true}

      Accounts.sign_in_from_github(profile, tokens, config: config, org_member?: org_member?)
    end
  end

  # -- user tokens ---------------------------------------------------------------

  @doc """
  A current access token for `user`, refreshing it when it has less than
  `min_life` seconds left (five minutes by default).
  `{:error, :login_expired}` means the refresh token is gone or rejected
  and the user has to sign in again.
  """
  def user_token(%User{id: user_id}, min_life \\ @refresh_margin) do
    # GitHub spends the old refresh token as soon as it answers, so the
    # refresh runs unlinked: if the caller dies, it still stores the new one.
    callers = [self() | Process.get(:"$callers", [])]
    ref = make_ref()
    caller = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        send(caller, {ref, locked_user_token(user_id, min_life)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        Logger.error("GitHub token refresh crashed: #{inspect(reason)}")
        {:error, :refresh_failed}
    end
  end

  defp locked_user_token(user_id, min_life) do
    :global.trans({{__MODULE__, :refresh, user_id}, self()}, fn ->
      user = Accounts.get_user!(user_id)

      cond do
        fresh?(user, min_life) -> {:ok, user.access_token}
        is_nil(user.refresh_token) -> {:error, :login_expired}
        true -> refresh(user)
      end
    end)
  end

  defp fresh?(%User{access_token: nil}, _min_life), do: false
  defp fresh?(%User{access_token_expires_at: nil}, _min_life), do: true

  defp fresh?(%User{access_token_expires_at: expires}, min_life) do
    DateTime.diff(expires, DateTime.utc_now()) > min_life
  end

  defp refresh(user) do
    case Client.refresh_user_token(app(), user.refresh_token) do
      {:ok, tokens} ->
        {:ok, user} = Accounts.update_tokens(user, tokens)
        recheck_access(user)

      {:error, :bad_refresh_token} ->
        login_expired(user)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks that a signed-in user may still use Crew (§18.1: at every token
  refresh and every six hours). A token that needs refreshing is
  refreshed, which checks; otherwise the current one is used.
  """
  def check_access(%User{} = user) do
    if fresh?(user, @refresh_margin) do
      recheck_access(user)
    else
      user_token(user)
    end
  end

  # Who may use Crew can change after sign-in (someone leaves the org
  # or an allowlist), so every refresh checks again with the new token.
  # Only a definite "no" ends their access; a GitHub error changes nothing.
  defp recheck_access(user) do
    config = Accounts.login_config()

    verdict =
      case Accounts.access(user, config) do
        :ask_org -> org_verdict(user, config.allowed_org)
        verdict -> verdict
      end

    if verdict == :denied do
      Logger.warning("#{user.login} may no longer use Crew; ending their sessions")
      :ok = Accounts.revoke_access(user, "no longer allowed at token refresh")
      {:error, :login_expired}
    else
      Accounts.mark_access_checked(user)
      {:ok, user.access_token}
    end
  end

  defp org_verdict(user, org) do
    case Client.org_membership(user.access_token, org) do
      {:ok, true} ->
        :allowed

      {:ok, false} ->
        :denied

      {:error, reason} ->
        Logger.warning("couldn't check #{user.login}'s membership of #{org}: #{inspect(reason)}")
        :allowed
    end
  end

  defp login_expired(user) do
    case Accounts.mark_github_login_expired(user) do
      :ok ->
        Logger.warning(
          "GitHub refresh token for #{user.login} was rejected; they need to sign in again"
        )

        Phoenix.PubSub.broadcast(Crew.PubSub, "user:#{user.id}", :github_login_expired)
        {:error, :login_expired}

      # They signed in again while the refresh was in flight.
      :stale ->
        case Accounts.get_user!(user.id) do
          %User{access_token: token} when is_binary(token) -> {:ok, token}
          _ -> {:error, :login_expired}
        end
    end
  end
end
