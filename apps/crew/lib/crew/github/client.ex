defmodule Crew.GitHub.Client do
  @moduledoc """
  Every call Crew makes to GitHub goes through here (§6.6), over Req.

  Tests stub GitHub with `Req.Test` (the `:github_req_options` config
  adds `plug: {Req.Test, Crew.GitHub}`), so they run against recorded
  responses rather than a mock of this module.

  `app` is the GitHub App's credentials:
  `%{app_id:, client_id:, client_secret:, private_key:, slug:}`.
  """

  require Logger

  alias Crew.GitHub.JWT

  @doc "GitHub's API. Configurable so end-to-end runs can use a fake GitHub."
  def api_url, do: Application.get_env(:crew, :github_api_url) || "https://api.github.com"

  @doc "GitHub's website, for OAuth and the App pages."
  def web_url, do: Application.get_env(:crew, :github_web_url) || "https://github.com"

  @type app :: map()
  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_in: integer() | nil,
          refresh_token_expires_in: integer() | nil
        }

  @doc false
  def api(opts \\ []) do
    Req.new(
      base_url: api_url(),
      headers: [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "crew"}
      ],
      retry: :transient,
      max_retries: 2
    )
    |> Req.merge(opts)
    |> Req.merge(Application.get_env(:crew, :github_req_options, []))
  end

  defp bearer(token), do: [auth: {:bearer, token}]

  # -- user OAuth ---------------------------------------------------------------

  @spec exchange_code(app, String.t(), String.t(), String.t()) ::
          {:ok, tokens} | {:error, term()}
  def exchange_code(app, code, verifier, redirect_uri) do
    oauth_token(%{
      client_id: app.client_id,
      client_secret: app.client_secret,
      code: code,
      code_verifier: verifier,
      redirect_uri: redirect_uri
    })
  end

  @spec refresh_user_token(app, String.t()) :: {:ok, tokens} | {:error, term()}
  def refresh_user_token(app, refresh_token) do
    case oauth_token(%{
           client_id: app.client_id,
           client_secret: app.client_secret,
           grant_type: "refresh_token",
           refresh_token: refresh_token
         }) do
      {:error, {:oauth, "bad_refresh_token"}} -> {:error, :bad_refresh_token}
      other -> other
    end
  end

  defp oauth_token(form) do
    req = api(base_url: web_url(), headers: [{"accept", "application/json"}])

    case Req.post(req, url: "/login/oauth/access_token", form: form) do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}} ->
        {:ok,
         %{
           access_token: token,
           refresh_token: body["refresh_token"],
           expires_in: body["expires_in"],
           refresh_token_expires_in: body["refresh_token_expires_in"]
         }}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, {:oauth, error}}

      other ->
        unexpected(other)
    end
  end

  @spec get_user(String.t()) :: {:ok, map()} | {:error, term()}
  def get_user(token) do
    case Req.get(api(bearer(token)), url: "/user") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      other -> unexpected(other)
    end
  end

  @doc """
  Whether the token's user is an active member of `org`. `{:ok, false}`
  only when GitHub says so; anything else that goes wrong is an error.
  """
  @spec org_membership(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def org_membership(token, org) do
    case Req.get(api(bearer(token)), url: "/user/memberships/orgs/#{URI.encode_www_form(org)}") do
      {:ok, %{status: 200, body: %{"state" => state}}} -> {:ok, state == "active"}
      # GitHub answers 404 when the user isn't a member, but also when the
      # org can't be seen at all; only the first is an answer.
      {:ok, %{status: 404}} -> org_exists(token, org)
      other -> unexpected(other)
    end
  end

  defp org_exists(token, org) do
    case Req.get(api(bearer(token)), url: "/orgs/#{URI.encode_www_form(org)}") do
      {:ok, %{status: 200}} ->
        {:ok, false}

      {:ok, %{status: 404}} ->
        Logger.error("GitHub can't find the org #{org}; is CREW_ALLOWED_ORG right?")
        {:error, :org_not_found}

      other ->
        unexpected(other)
    end
  end

  # -- the app ------------------------------------------------------------------

  @doc "Exchanges the manifest flow's code for the new app's credentials."
  @spec convert_manifest(String.t()) :: {:ok, map()} | {:error, term()}
  def convert_manifest(code) do
    case Req.post(api(), url: "/app-manifests/#{URI.encode_www_form(code)}/conversions") do
      {:ok, %{status: 201, body: body}} -> {:ok, body}
      other -> unexpected(other)
    end
  end

  @spec list_installations(app) :: {:ok, [map()]} | {:error, term()}
  def list_installations(app) do
    paginate(api(bearer(app_jwt(app))), "/app/installations", & &1)
  end

  @spec installation_token(app, integer()) :: {:ok, String.t()} | {:error, term()}
  def installation_token(app, installation_id) do
    case Req.post(api(bearer(app_jwt(app))),
           url: "/app/installations/#{installation_id}/access_tokens"
         ) do
      {:ok, %{status: 201, body: %{"token" => token}}} -> {:ok, token}
      other -> unexpected(other)
    end
  end

  @spec list_installation_repos(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_installation_repos(token) do
    paginate(api(bearer(token)), "/installation/repositories", & &1["repositories"])
  end

  # -- helpers --------------------------------------------------------------------

  defp paginate(req, url, extract, max_pages \\ 50) do
    Enum.reduce_while(1..max_pages, {:ok, []}, fn page, {:ok, acc} ->
      case Req.get(req, url: url, params: [per_page: 100, page: page]) do
        {:ok, %{status: 200, body: body}} ->
          items = extract.(body) || []
          acc = acc ++ items

          cond do
            length(items) < 100 -> {:halt, {:ok, acc}}
            page < max_pages -> {:cont, {:ok, acc}}
            true -> {:halt, {:error, :too_many_pages}}
          end

        other ->
          {:halt, unexpected(other)}
      end
    end)
  end

  @doc false
  def app_jwt(app), do: JWT.app_token(app.client_id || app.app_id, app.private_key)

  defp unexpected({:ok, %Req.Response{status: status, body: body}}) do
    message = if is_map(body), do: body["message"], else: nil
    {:error, {:http, status, message}}
  end

  defp unexpected({:error, exception}), do: {:error, exception}
end
