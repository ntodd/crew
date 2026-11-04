defmodule CrewCache.Mgmt do
  @moduledoc """
  The management API (§15.8), HTTP on `CREW_CACHE_MGMT_LISTEN`
  (127.0.0.1:7780). With `CREW_CACHE_MGMT_TOKEN` set, every request
  needs `Authorization: Bearer <token>`; off loopback the token is
  required (`CrewCache.Config`).

  | Endpoint | Body | Answer |
  |---|---|---|
  | `GET /stats` | | `{hosts: [{host, hits, misses, bytes_served, bytes_stored, mismatches}], evictions, digest_mismatches, top: [{host, repo, hits, bytes_served}], store: {bytes, max_bytes, objects}}` |
  | `POST /config` | any of `enabled_hosts`, `allowlist`, `parent` ({url, token, ca_pem} or null), `rotate_ca`, `site4` | `{ok: true, ca_rotated}`, or 422 `{error}` |
  | `POST /purge` | `{scope}`: `all`, `host:<host>` or `repo:<host>/<repository>` | `{ok: true, removed, bytes}` |
  | `POST /evict` | `{target_bytes}` | `{ok: true, evicted, bytes, store_bytes}` |
  | `GET /ca.pem` | | The root certificate |
  | `GET /host` | | `{reboot_required, packages, boot_id}` |

  `hosts` lists every compiled host. Counters run from the cache's
  start; `bytes_stored` is what the store holds now. `top` is the 10
  repositories that served the most bytes since the start.
  """
  @behaviour Plug

  import Plug.Conn

  alias CrewCache.{CA, Config, Settings, Stats, Store}
  alias CrewProtocol.Hosts

  @max_body 256 * 1024

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    if authorized?(conn, Keyword.get(opts, :token)) do
      route(conn, conn.method, conn.path_info)
    else
      conn
      |> put_resp_header("www-authenticate", "Bearer")
      |> json(401, %{"error" => "unauthorized"})
    end
  end

  defp authorized?(_conn, token) when token in [nil, ""], do: true

  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> given] -> Plug.Crypto.secure_compare(given, token)
      _ -> false
    end
  end

  defp route(conn, "GET", ["stats"]), do: json(conn, 200, stats())
  defp route(conn, "POST", ["config"]), do: with_body(conn, &config/2)
  defp route(conn, "POST", ["purge"]), do: with_body(conn, &purge/2)
  defp route(conn, "POST", ["evict"]), do: with_body(conn, &evict/2)

  defp route(conn, "GET", ["ca.pem"]) do
    conn |> put_resp_content_type("application/x-pem-file", nil) |> send_resp(200, CA.root_pem())
  end

  defp route(conn, "GET", ["host"]), do: json(conn, 200, host(Config.get().host_root))

  defp route(conn, _method, [path]) when path in ~w(stats config purge evict ca.pem host),
    do: json(conn, 405, %{"error" => "method not allowed"})

  defp route(conn, _method, _path), do: json(conn, 404, %{"error" => "not found"})

  defp with_body(conn, fun) do
    with {:ok, body, conn} <- read_body(conn, length: @max_body),
         {:ok, %{} = params} <- Jason.decode(body) do
      fun.(conn, params)
    else
      {:more, _, conn} -> json(conn, 413, %{"error" => "body too large"})
      _ -> json(conn, 400, %{"error" => "the body must be a JSON object"})
    end
  end

  # -- endpoints ------------------------------------------------------------------

  def stats do
    snapshot = Stats.snapshot()
    usage = Store.usage()
    empty = %{hits: 0, misses: 0, bytes_served: 0, mismatches: 0}

    %{
      "hosts" =>
        for host <- Hosts.names() do
          counters = Map.get(snapshot.hosts, host, empty)

          %{
            "host" => host,
            "hits" => counters.hits,
            "misses" => counters.misses,
            "bytes_served" => counters.bytes_served,
            "bytes_stored" => Map.get(usage.by_host, host, 0),
            "mismatches" => counters.mismatches
          }
        end,
      "evictions" => snapshot.evictions,
      "digest_mismatches" => snapshot.digest_mismatches,
      "top" => snapshot.top,
      "store" => %{
        "bytes" => usage.bytes,
        "max_bytes" => usage.max_bytes,
        "objects" => usage.objects
      }
    }
  end

  defp config(conn, params) do
    case Settings.apply(params) do
      {:ok, %{ca_rotated: rotated}} -> json(conn, 200, %{"ok" => true, "ca_rotated" => rotated})
      {:error, message} -> json(conn, 422, %{"error" => message})
    end
  end

  defp purge(conn, params) do
    case scope(params["scope"]) do
      {:ok, scope} ->
        {:ok, %{removed: removed, bytes: bytes}} = Store.purge(scope)
        json(conn, 200, %{"ok" => true, "removed" => removed, "bytes" => bytes})

      :error ->
        json(conn, 422, %{"error" => "scope must be all, host:<host> or repo:<host>/<repository>"})
    end
  end

  @doc "A `cache.purge` scope (§10.3) as the store takes it."
  def scope("all"), do: {:ok, :all}

  def scope("host:" <> host) do
    if host in Hosts.names(), do: {:ok, {:host, host}}, else: :error
  end

  def scope("repo:" <> rest) do
    with [host, repo] <- String.split(rest, "/", parts: 2),
         true <- host in Hosts.names(),
         true <- Regex.match?(~r/\A[a-z0-9._\/-]+\z/, repo),
         false <- String.contains?(repo, ["..", "//"]) do
      {:ok, {:repo, host, repo}}
    else
      _ -> :error
    end
  end

  def scope(_), do: :error

  defp evict(conn, %{"target_bytes" => target}) when is_integer(target) and target >= 0 do
    {:ok, result} = Store.evict_to(target)

    json(conn, 200, %{
      "ok" => true,
      "evicted" => result.evicted,
      "bytes" => result.bytes,
      "store_bytes" => result.store_bytes
    })
  end

  defp evict(conn, _),
    do: json(conn, 422, %{"error" => "target_bytes must be a non-negative integer"})

  @doc "The host's reboot state (§12.1), from under `root`."
  def host(root) do
    packages =
      case File.read(Path.join(root, "run/reboot-required.pkgs")) do
        {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.uniq() |> Enum.take(50)
        {:error, _} -> []
      end

    boot_id =
      case File.read(Path.join(root, "proc/sys/kernel/random/boot_id")) do
        {:ok, text} -> String.trim(text)
        {:error, _} -> nil
      end

    %{
      "reboot_required" => File.exists?(Path.join(root, "run/reboot-required")),
      "packages" => packages,
      "boot_id" => boot_id
    }
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
