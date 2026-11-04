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

  @doc "A new installation token, and when it expires (Unix seconds)."
  def create_installation_token(app, installation_id) do
    case Req.post(api(bearer(app_jwt(app))),
           url: "/app/installations/#{installation_id}/access_tokens"
         ) do
      {:ok, %{status: 201, body: %{"token" => token} = body}} ->
        expires_at =
          case DateTime.from_iso8601(body["expires_at"] || "") do
            {:ok, dt, _} -> DateTime.to_unix(dt)
            _ -> System.os_time(:second) + 3600
          end

        {:ok, %{token: token, expires_at: expires_at}}

      other ->
        unexpected(other)
    end
  end

  @doc "One installation, by id (app JWT)."
  def get_installation(app, installation_id) do
    case Req.get(api(bearer(app_jwt(app))), url: "/app/installations/#{installation_id}") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      other -> unexpected(other)
    end
  end

  @doc """
  A page of the App's webhook deliveries, newest first (app JWT, §6.2),
  and the cursor for the next page, if any.
  """
  def list_hook_deliveries(app, cursor \\ nil) do
    params = [per_page: 100] ++ if(cursor, do: [cursor: cursor], else: [])

    case Req.get(api(bearer(app_jwt(app))), url: "/app/hook/deliveries", params: params) do
      {:ok, %{status: 200, body: items} = resp} when is_list(items) ->
        {:ok, items, next_cursor(resp)}

      other ->
        unexpected(other)
    end
  end

  defp next_cursor(resp) do
    with [link | _] <- Req.Response.get_header(resp, "link"),
         [_, url] <- Regex.run(~r/<([^>]+)>;\s*rel="next"/, link),
         %URI{query: query} when is_binary(query) <- URI.parse(url) do
      URI.decode_query(query)["cursor"]
    else
      _ -> nil
    end
  end

  @doc "Asks GitHub to deliver a webhook again (§6.2)."
  def redeliver(app, delivery_id) do
    case Req.post(api(bearer(app_jwt(app))), url: "/app/hook/deliveries/#{delivery_id}/attempts") do
      {:ok, %{status: status}} when status in [200, 202] -> :ok
      other -> unexpected(other)
    end
  end

  # -- installation requests (§6.6) ----------------------------------------------

  @doc """
  A request as an installation, through the budget. Options:
  `class:` (`:essential`, `:normal` (the default) or `:optional`),
  `kind:` (`:read`, `:jit`, `:delete`, `:write`; from the method by
  default), `endpoint:` (the URL template for telemetry), and Req's
  `json:`, `params:` and `redirect:`.
  """
  # Reads are retried on transient failures, each try through the budget
  # so it counts and its headers are seen. Writes aren't retried here:
  # their callers (Oban jobs, the VM server) decide.
  @read_retries 2

  def installation_request(installation_id, method, url, opts \\ []) do
    retries = if method == :get, do: Keyword.get(opts, :retries, @read_retries), else: 0
    attempt_request(installation_id, method, url, opts, retries)
  end

  defp attempt_request(installation_id, method, url, opts, retries) do
    case one_request(installation_id, method, url, opts) do
      {:ok, %Req.Response{status: status}} when status in [500, 502, 503, 504] and retries > 0 ->
        Process.sleep(retry_delay(retries))
        attempt_request(installation_id, method, url, opts, retries - 1)

      {:error, %{__exception__: true}} when retries > 0 ->
        Process.sleep(retry_delay(retries))
        attempt_request(installation_id, method, url, opts, retries - 1)

      other ->
        other
    end
  end

  defp retry_delay(retries),
    do: Application.get_env(:crew, :github_retry_ms, 500) * (@read_retries - retries + 1)

  defp one_request(installation_id, method, url, opts) do
    class = Keyword.get(opts, :class, :normal)
    kind = Keyword.get_lazy(opts, :kind, fn -> if method == :get, do: :read, else: :write end)
    endpoint = Keyword.get(opts, :endpoint, url)

    req_opts =
      [retry: false] ++ Keyword.take(opts, [:json, :params, :redirect, :decode_body, :into])

    with {:ok, ref} <- Crew.GitHub.Budget.acquire(installation_id, class, kind) do
      started = System.monotonic_time()

      result =
        with_token(installation_id, fn token ->
          Req.request(api(bearer(token)), [method: method, url: url] ++ req_opts)
        end)

      {status, headers} =
        case result do
          {:ok, %Req.Response{status: status, headers: headers}} -> {status, headers}
          _ -> {0, %{}}
        end

      Crew.GitHub.Budget.release(installation_id, ref, status, headers)

      :telemetry.execute(
        [:crew, :github, :request],
        %{duration: System.monotonic_time() - started},
        %{
          endpoint: "#{method |> to_string() |> String.upcase()} #{endpoint}",
          status: status,
          class: class,
          installation_id: installation_id
        }
      )

      result
    end
  end

  # A 401 means the cached token went bad (revoked, or the App's key
  # rotated): drop it and try once more with a fresh one.
  defp with_token(installation_id, fun) do
    with {:ok, token} <- Crew.GitHub.InstallationTokens.get(installation_id) do
      case fun.(token) do
        {:ok, %Req.Response{status: 401}} ->
          Crew.GitHub.InstallationTokens.invalidate(installation_id)

          with {:ok, token} <- Crew.GitHub.InstallationTokens.get(installation_id),
               do: fun.(token)

        other ->
          other
      end
    end
  end

  defp get_json(installation_id, url, endpoint, opts) do
    case installation_request(installation_id, :get, url, [endpoint: endpoint] ++ opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      other -> unexpected(other)
    end
  end

  # Pages of 100 until a short page, at most `max_pages`.
  defp get_pages(installation_id, url, endpoint, key, opts, max_pages \\ 20) do
    Enum.reduce_while(1..max_pages, {:ok, []}, fn page, {:ok, acc} ->
      params = Keyword.get(opts, :params, []) ++ [per_page: 100, page: page]

      case get_json(installation_id, url, endpoint, Keyword.put(opts, :params, params)) do
        {:ok, body} ->
          items = body[key] || []
          acc = acc ++ items
          if length(items) < 100, do: {:halt, {:ok, acc}}, else: {:cont, {:ok, acc}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp repo_path(full_name), do: "/repos/" <> full_name

  @doc "The repos of an installation the user's token can see, with `permissions` (§18.3)."
  def user_installation_repos(user_token, installation_id) do
    paginate(
      api(bearer(user_token)),
      "/user/installations/#{installation_id}/repositories",
      & &1["repositories"]
    )
  end

  @doc "The repos an installation can see."
  def list_installation_repos(installation_id, opts \\ []) do
    get_pages(
      installation_id,
      "/installation/repositories",
      "/installation/repositories",
      "repositories",
      opts
    )
  end

  @doc "A run attempt (§6.5: essential, it drives the fork check)."
  def get_run_attempt(installation_id, repo, run_id, attempt, opts \\ []) do
    get_json(
      installation_id,
      "#{repo_path(repo)}/actions/runs/#{run_id}/attempts/#{attempt}",
      "/repos/{o}/{r}/actions/runs/{id}/attempts/{n}",
      Keyword.put_new(opts, :class, :essential)
    )
  end

  @doc "A run attempt's jobs (§6.5: Crew fetches per attempt, never per job)."
  def list_attempt_jobs(installation_id, repo, run_id, attempt, opts \\ []) do
    get_pages(
      installation_id,
      "#{repo_path(repo)}/actions/runs/#{run_id}/attempts/#{attempt}/jobs",
      "/repos/{o}/{r}/actions/runs/{id}/attempts/{n}/jobs",
      "jobs",
      Keyword.put_new(opts, :class, :essential)
    )
  end

  @doc "One job (§6.5)."
  def get_job(installation_id, repo, job_id, opts \\ []) do
    get_json(
      installation_id,
      "#{repo_path(repo)}/actions/jobs/#{job_id}",
      "/repos/{o}/{r}/actions/jobs/{id}",
      opts
    )
  end

  @doc """
  Where a job's log is (§16.3): GitHub answers with a redirect to a
  short-lived download URL, or 404 while the log isn't ready yet.
  """
  def job_log_location(installation_id, repo, job_id) do
    case installation_request(
           installation_id,
           :get,
           "#{repo_path(repo)}/actions/jobs/#{job_id}/logs",
           endpoint: "/repos/{o}/{r}/actions/jobs/{id}/logs",
           redirect: false,
           retries: 0
         ) do
      {:ok, %{status: status} = resp} when status in [301, 302, 307] ->
        case Req.Response.get_header(resp, "location") do
          [url | _] -> {:ok, {:url, url}}
          [] -> {:error, :no_location}
        end

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, {:body, body}}

      {:ok, %{status: status}} when status in [404, 410] ->
        {:error, :not_found}

      other ->
        unexpected(other)
    end
  end

  @doc """
  Downloads a log from the URL GitHub redirected to. It's another host,
  so no token goes with it, and at most `limit` bytes are kept:
  `{:ok, body, cut?}`.
  """
  def download_log(url, limit) do
    into = fn {:data, data}, {req, resp} ->
      kept = resp.body || ""
      room = limit - byte_size(kept)

      if byte_size(data) >= room do
        resp =
          %{resp | body: kept <> binary_part(data, 0, max(room, 0))}
          |> Req.Response.put_private(:cut, true)

        {:halt, {req, resp}}
      else
        {:cont, {req, %{resp | body: kept <> data}}}
      end
    end

    req =
      Req.new(
        url: url,
        retry: :transient,
        max_retries: 2,
        redirect: false,
        into: into,
        decode_body: false
      )
      |> Req.merge(Application.get_env(:crew, :github_req_options, []))

    case Req.request(req) do
      {:ok, %{status: 200} = resp} ->
        {:ok, resp.body || "", Req.Response.get_private(resp, :cut, false)}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "A repo's runs with a status (`queued`, `in_progress`), for the reconciler."
  def list_runs(installation_id, repo, status, opts \\ []) do
    get_pages(
      installation_id,
      "#{repo_path(repo)}/actions/runs",
      "/repos/{o}/{r}/actions/runs",
      "workflow_runs",
      Keyword.merge([class: :essential, params: [status: status]], opts),
      5
    )
  end

  @doc """
  A repo-level JIT runner (§6.3): `{:ok, %{runner_id, jit_config}}`. The
  JIT config is a credential; callers keep it in memory only.
  """
  def generate_jit_config(installation_id, repo, name, labels) do
    case installation_request(
           installation_id,
           :post,
           "#{repo_path(repo)}/actions/runners/generate-jitconfig",
           class: :essential,
           kind: :jit,
           endpoint: "/repos/{o}/{r}/actions/runners/generate-jitconfig",
           json: %{name: name, runner_group_id: 1, labels: labels, work_folder: "_work"}
         ) do
      {:ok, %{status: 201, body: %{"runner" => %{"id" => id}, "encoded_jit_config" => jit}}} ->
        {:ok, %{runner_id: id, jit_config: jit}}

      other ->
        unexpected(other)
    end
  end

  @doc """
  Deletes a runner (§6.3): `:gone` on 204 or 404, `:busy` on 422 (it has
  a job), an error otherwise.
  """
  def delete_runner(installation_id, repo, runner_id) do
    case installation_request(
           installation_id,
           :delete,
           "#{repo_path(repo)}/actions/runners/#{runner_id}",
           class: :essential,
           kind: :delete,
           endpoint: "/repos/{o}/{r}/actions/runners/{id}"
         ) do
      {:ok, %{status: status}} when status in [204, 404] -> {:ok, :gone}
      {:ok, %{status: 422}} -> {:ok, :busy}
      other -> unexpected(other)
    end
  end

  @doc "A repo's self-hosted runners (for GC, §6.3)."
  def list_runners(installation_id, repo, opts \\ []) do
    get_pages(
      installation_id,
      "#{repo_path(repo)}/actions/runners",
      "/repos/{o}/{r}/actions/runners",
      "runners",
      Keyword.put_new(opts, :class, :normal)
    )
  end

  @doc "Re-runs a run, all its jobs (a person's Re-run all, §17.3)."
  def rerun(installation_id, repo, run_id), do: run_post(installation_id, repo, run_id, "rerun")

  @doc "Re-runs a run's failed jobs (§17.3)."
  def rerun_failed(installation_id, repo, run_id),
    do: run_post(installation_id, repo, run_id, "rerun-failed-jobs")

  defp run_post(installation_id, repo, run_id, what) do
    case installation_request(
           installation_id,
           :post,
           "#{repo_path(repo)}/actions/runs/#{run_id}/#{what}",
           endpoint: "/repos/{o}/{r}/actions/runs/{id}/#{what}",
           class: :normal
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> unexpected(other)
    end
  end

  @doc "Cancels a run (fork refusal, §19.5; or a person's Cancel)."
  def cancel_run(installation_id, repo, run_id, opts \\ []) do
    case installation_request(
           installation_id,
           :post,
           "#{repo_path(repo)}/actions/runs/#{run_id}/cancel",
           Keyword.merge(
             [class: :essential, endpoint: "/repos/{o}/{r}/actions/runs/{id}/cancel"],
             opts
           )
         ) do
      {:ok, %{status: status}} when status in [202, 409] -> :ok
      other -> unexpected(other)
    end
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
