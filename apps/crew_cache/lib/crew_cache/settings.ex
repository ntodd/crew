defmodule CrewCache.Settings do
  @moduledoc """
  What `POST /config` changes (§15.8), kept in `<cache dir>/config.json`
  (0600: it holds the parent's token):

  - `enabled_hosts`: a subset of the compiled hosts (default: all);
  - `allowlist`: `<host>/<glob>` entries (default: the protocol's);
  - `parent`: `{url, token, ca_pem}` or nil;
  - `site4`: CIDRs from the agent (the site's egress address and
    `CREW_EXTRA_BLOCKED`), added to the cache's own: its connected
    subnets, refreshed every 10 minutes, and its `extra_blocked`.

  Each field is optional in an update; what's absent is unchanged.
  `rotate_ca: true` regenerates the CA chain. Under Design A a change of
  enabled hosts leaves the chain alone: its constraints name the IP,
  not hosts.

  Request handlers read `current/0`, a persistent term.
  """
  use GenServer

  require Logger

  alias CrewCache.{Allowlist, Net}
  alias CrewProtocol.Hosts

  @file_name "config.json"
  @refresh_ms 10 * 60_000
  @fields ~w(enabled_hosts allowlist parent rotate_ca site4 parent_tokens)

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @doc "`%{enabled: MapSet, allow: compiled allowlist, parent: nil | map}`."
  def current, do: :persistent_term.get({__MODULE__, :current})

  @doc "The saved settings, without the parent's token."
  def saved, do: GenServer.call(__MODULE__, :saved)

  @doc "Validate and apply an update. `{:ok, %{ca_rotated: bool}}` or `{:error, message}`."
  def apply(params) when is_map(params), do: GenServer.call(__MODULE__, {:apply, params}, 30_000)

  # -- validation -------------------------------------------------------------

  defp validate(params, saved) do
    with :ok <- known_fields(params),
         {:ok, saved} <- field(params, "enabled_hosts", saved, &enabled_hosts/1),
         {:ok, saved} <- field(params, "allowlist", saved, &allowlist/1),
         {:ok, saved} <- field(params, "parent", saved, &parent/1),
         {:ok, saved} <- field(params, "site4", saved, &site4/1),
         :ok <- parent_tokens(params["parent_tokens"]),
         {:ok, rotate?} <- rotate(params["rotate_ca"]) do
      {:ok, saved, rotate?}
    end
  end

  defp known_fields(params) do
    case Map.keys(params) -- @fields do
      [] -> :ok
      [key | _] -> {:error, "#{key} isn't a setting"}
    end
  end

  defp field(params, key, saved, check) do
    case Map.fetch(params, key) do
      :error ->
        {:ok, saved}

      {:ok, value} ->
        with {:ok, value} <- check.(value), do: {:ok, Map.put(saved, key, value)}
    end
  end

  defp enabled_hosts(list) when is_list(list) do
    case Enum.reject(list, &(&1 in Hosts.names())) do
      [] -> {:ok, Enum.uniq(list)}
      [bad | _] -> {:error, "enabled_hosts: #{inspect(bad)} isn't a host Crew knows"}
    end
  end

  defp enabled_hosts(_), do: {:error, "enabled_hosts must be a list"}

  defp allowlist(list) when is_list(list) and length(list) <= 500 do
    case Enum.reject(list, &Hosts.allowlist_entry?/1) do
      [] -> {:ok, Enum.uniq(list)}
      [bad | _] -> {:error, "allowlist: #{inspect(bad)} isn't <known host>/<repository glob>"}
    end
  end

  defp allowlist(_), do: {:error, "allowlist must be a list of at most 500 entries"}

  defp parent(nil), do: {:ok, nil}

  defp parent(%{"url" => url, "token" => token, "ca_pem" => pem})
       when is_binary(url) and is_binary(token) and is_binary(pem) do
    cond do
      not https_url?(url) ->
        {:error, "parent.url must be an https URL"}

      token == "" or byte_size(token) > 256 ->
        {:error, "parent.token must be 1 to 256 characters"}

      byte_size(pem) > 16_384 or cacerts(pem) == [] ->
        {:error, "parent.ca_pem must be a PEM certificate"}

      true ->
        {:ok, %{"url" => String.trim_trailing(url, "/"), "token" => token, "ca_pem" => pem}}
    end
  end

  defp parent(_), do: {:error, "parent must be null or {url, token, ca_pem}"}

  defp https_url?(url) do
    uri = URI.parse(url)
    uri.scheme == "https" and uri.host not in [nil, ""] and byte_size(url) <= 512
  end

  defp site4(list) when is_list(list) and length(list) <= 256 do
    case Enum.reject(list, &match?({:ok, _}, Net.parse_cidr(&1))) do
      [] -> {:ok, Enum.uniq(list)}
      [bad | _] -> {:error, "site4: #{inspect(bad)} isn't an IPv4 CIDR"}
    end
  end

  defp site4(_), do: {:error, "site4 must be a list of at most 256 CIDRs"}

  defp parent_tokens(nil), do: :ok
  defp parent_tokens([]), do: :ok
  defp parent_tokens(_), do: {:error, "parent_tokens is for parent mode, which isn't built"}

  defp rotate(nil), do: {:ok, false}
  defp rotate(bool) when is_boolean(bool), do: {:ok, bool}
  defp rotate(_), do: {:error, "rotate_ca must be a boolean"}

  defp cacerts(pem) do
    for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der
  rescue
    _ -> []
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(config) do
    saved =
      Map.merge(
        %{
          "enabled_hosts" => Hosts.names(),
          "allowlist" => Hosts.default_allowlist(),
          "parent" => nil,
          "site4" => []
        },
        load(config.dir)
      )

    state = %{config: config, saved: saved, connected: connected()}
    publish(state)
    Process.send_after(self(), :refresh, @refresh_ms)
    {:ok, state}
  end

  defp load(dir) do
    with {:ok, json} <- File.read(Path.join(dir, @file_name)),
         {:ok, %{} = map} <- Jason.decode(json),
         {:ok, saved, _} <- validate(Map.take(map, @fields), %{}) do
      saved
    else
      {:error, :enoent} ->
        %{}

      # Never the file itself: it holds the parent's token.
      {:error, message} when is_binary(message) ->
        Logger.error("ignoring #{@file_name}: #{message}")
        %{}

      _ ->
        Logger.error("ignoring #{@file_name}: it isn't a JSON object of settings")
        %{}
    end
  end

  defp connected do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} -> Net.connected(ifaddrs)
      _ -> []
    end
  end

  @impl true
  def handle_call({:apply, params}, _from, state) do
    case validate(params, state.saved) do
      {:ok, saved, rotate?} ->
        state = %{state | saved: saved}
        save(state)
        publish(state)
        if Map.has_key?(params, "parent"), do: CrewCache.Parent.reconfigure()
        if rotate?, do: :ok = CrewCache.CA.rotate()
        {:reply, {:ok, %{ca_rotated: rotate?}}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:saved, _from, state) do
    parent = state.saved["parent"] && Map.delete(state.saved["parent"], "token")
    {:reply, %{state.saved | "parent" => parent}, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, @refresh_ms)
    state = %{state | connected: connected()}
    publish(state)
    {:noreply, state}
  end

  # Crash reports and :sys.get_status print the state and the last
  # message ({:apply, params}): neither may show the parent's token.
  @impl true
  def format_status(status) do
    Enum.reduce([:state, :message, :log], status, fn key, status ->
      if Map.has_key?(status, key), do: Map.update!(status, key, &redact/1), else: status
    end)
  end

  defp redact(%_{} = struct), do: struct

  defp redact(%{} = map) do
    Map.new(map, fn
      {k, _} when k in ["token", :token] -> {k, "**redacted**"}
      {k, v} -> {k, redact(v)}
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)

  defp redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> redact() |> List.to_tuple()

  defp redact(other), do: other

  defp save(%{config: config, saved: saved}) do
    path = Path.join(config.dir, @file_name)
    tmp = path <> ".tmp"
    File.write!(tmp, "")
    File.chmod!(tmp, 0o600)
    File.write!(tmp, Jason.encode_to_iodata!(saved))
    File.rename!(tmp, path)
  end

  defp publish(%{config: config, saved: saved, connected: connected}) do
    site4 = config.extra_blocked ++ config.site4 ++ saved["site4"] ++ connected
    Net.put_current(Net.policy(site4, config.net_except))

    parent =
      case saved["parent"] do
        nil -> nil
        p -> %{url: p["url"], token: p["token"], cacerts: cacerts(p["ca_pem"])}
      end

    :persistent_term.put({__MODULE__, :current}, %{
      enabled: MapSet.new(saved["enabled_hosts"]),
      allow: Allowlist.compile(saved["allowlist"]),
      parent: parent
    })
  end
end
