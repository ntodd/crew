defmodule CrewAgent.GuestAPI do
  @moduledoc """
  The HTTP API the agent serves to job VMs (§13.4). **Nothing from the
  guest is trusted:** the job has root and can replace crew-guest.

  Where it listens:
  - **Firecracker:** `10.199.0.1:7777`, that address only. The source
    address must be the VM's lease address, and the token must belong to
    that lease's VM.
  - **vz:** one Unix socket per VM, `vms/<vm_id>/guest.sock`, which
    crew-vz forwards the guest's `10.199.0.1:7777` to. The socket
    identifies the VM (`vm_id:` in the plug's options), and the token
    must match it.
  - **null (dev):** 127.0.0.1, on `CREW_GUEST_API_PORT`.

  Auth is `Authorization: Bearer <token>`. Unknown or mismatched tokens
  get 401, at most 10 a minute per source; then the source is dropped
  for 60 s. At most 4 connections at once per VM.
  """
  @behaviour Plug

  import Plug.Conn

  alias CrewAgent.{Config, VM}

  @limits :crew_guest_limits
  @conns :crew_guest_conns
  @max_failures 10
  @failure_window_ms 60_000
  @drop_ms 60_000
  @max_conns 4
  @max_log_body 1_048_576
  @max_body 262_144

  # -- the listener --------------------------------------------------------------

  def child_spec(opts) do
    config = Config.get()
    port = Keyword.get(opts, :port, config.guest_api_port)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[ip: ip(config), port: port]]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    init_tables()

    {:ok, pid} =
      Bandit.start_link(
        plug: __MODULE__,
        scheme: :http,
        ip: opts[:ip],
        port: opts[:port],
        startup_log: false,
        thousand_island_options: [read_timeout: 10_000],
        http_1_options: [max_header_count: 32, max_request_line_length: 4_096]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    :persistent_term.put({__MODULE__, :port}, port)
    {:ok, pid}
  end

  @doc "Creates the ETS tables the API and the VMs share."
  def init_tables do
    for {t, opts} <- [
          {VM.sessions_table(), [:set, :public, :named_table, read_concurrency: true]},
          {@limits, [:set, :public, :named_table]},
          {@conns, [:set, :public, :named_table, write_concurrency: true]}
        ],
        :ets.whereis(t) == :undefined,
        do: :ets.new(t, opts)

    :ok
  end

  def port, do: :persistent_term.get({__MODULE__, :port}, 7777)

  @doc """
  vz (§13.4): a listener on the VM's own `guest.sock`, which crew-vz
  forwards the guest's 10.199.0.1:7777 to. It answers only for `vm_id`.
  The socket file is removed when the listener stops.
  """
  def start_socket(vm_id, path) do
    DynamicSupervisor.start_child(
      CrewAgent.GuestAPI.Sockets,
      {CrewAgent.GuestAPI.Socket, {vm_id, path}}
    )
  end

  def stop_socket(vm_id) do
    case Registry.lookup(CrewAgent.Registry, {:guest_socket, vm_id}) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp ip(%Config{driver: "firecracker", service_ip: service_ip}) do
    {:ok, ip} = :inet.parse_ipv4strict_address(String.to_charlist(service_ip))
    ip
  end

  defp ip(_config), do: {127, 0, 0, 1}

  @doc "The host a guest reaches the API at."
  def host(%Config{driver: "null"}), do: "127.0.0.1"
  def host(%Config{service_ip: ip}), do: ip

  # -- requests ------------------------------------------------------------------------

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    source = source(conn.remote_ip, Keyword.get(opts, :vm_id))

    if dropped?(source) do
      conn |> send_resp(429, "") |> halt()
    else
      case authenticate(conn, opts, source) do
        {:ok, vm_id} -> with_slot(conn, vm_id, fn -> route(conn, vm_id) end)
        :error -> conn |> send_resp(401, "") |> halt()
      end
    end
  end

  # A Unix socket (vz) has no peer address: its source is the socket,
  # which is one VM's. Keyed apart, so a guest guessing tokens is dropped
  # alone, not every VM on the box with it.
  defp source(_ip, pinned) when is_binary(pinned), do: "vm:" <> pinned
  defp source({_, _, _, _} = ip, nil), do: ip |> :inet.ntoa() |> to_string()
  defp source({_, _, _, _, _, _, _, _} = ip, nil), do: ip |> :inet.ntoa() |> to_string()
  defp source(_ip, nil), do: "local"

  defp authenticate(conn, opts, source) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         [{_, vm_id, guest_ip}] <- :ets.lookup(VM.sessions_table(), :crypto.hash(:sha256, token)),
         true <- source_ok?(opts, vm_id, guest_ip, source) do
      {:ok, vm_id}
    else
      _ ->
        failed(source)
        :error
    end
  end

  # The socket names the VM (vz); otherwise, on Firecracker, the source
  # address must be the lease's.
  defp source_ok?(opts, vm_id, guest_ip, source) do
    case Keyword.get(opts, :vm_id) do
      nil -> Config.get().driver != "firecracker" or guest_ip == source
      pinned -> pinned == vm_id
    end
  end

  defp failed(source) do
    now = System.monotonic_time(:millisecond)

    recent =
      case :ets.lookup(@limits, {:fail, source}) do
        [{_, times}] -> Enum.filter(times, &(&1 > now - @failure_window_ms))
        [] -> []
      end

    recent = [now | recent]
    :ets.insert(@limits, {{:fail, source}, recent})
    if length(recent) > @max_failures, do: :ets.insert(@limits, {{:drop, source}, now + @drop_ms})
  end

  defp dropped?(source) do
    case :ets.lookup(@limits, {:drop, source}) do
      [{_, until}] -> System.monotonic_time(:millisecond) < until
      [] -> false
    end
  end

  defp with_slot(conn, vm_id, fun) do
    if :ets.update_counter(@conns, vm_id, {2, 1}, {vm_id, 0}) > @max_conns do
      :ets.update_counter(@conns, vm_id, {2, -1})
      conn |> send_resp(429, "") |> halt()
    else
      try do
        fun.()
      after
        :ets.update_counter(@conns, vm_id, {2, -1}, {vm_id, 1})
      end
    end
  end

  defp route(%{method: "GET", path_info: ["v1", "payload"]} = conn, vm_id) do
    case VM.call(vm_id, :payload) do
      {:ok, body} -> json(conn, 200, body)
      {:error, :gone} -> send_resp(conn, 410, "")
      {:error, _} -> send_resp(conn, 404, "")
    end
  end

  defp route(%{method: "POST", path_info: ["v1", what]} = conn, vm_id)
       when what in ["state", "steps", "metrics"] do
    with {:ok, body, conn} <- read_limited(conn, @max_body),
         {:ok, decoded} <- Jason.decode(body) do
      reply(conn, VM.call(vm_id, {String.to_existing_atom(what), decoded}))
    else
      {:too_large, conn} -> send_resp(conn, 413, "")
      _ -> send_resp(conn, 400, "")
    end
  end

  defp route(%{method: "POST", path_info: ["v1", "log"]} = conn, vm_id) do
    case read_limited(conn, @max_log_body) do
      {:ok, body, conn} -> reply(conn, VM.call(vm_id, {:log, body}))
      {:too_large, conn} -> send_resp(conn, 413, "")
      _ -> send_resp(conn, 400, "")
    end
  end

  defp route(%{method: "GET", path_info: ["v1", "control"]} = conn, vm_id) do
    case VM.call(vm_id, :control, 35_000) do
      {:ok, body} -> json(conn, 200, body)
      :timeout -> send_resp(conn, 204, "")
      {:error, :busy} -> send_resp(conn, 409, "")
      {:error, _} -> send_resp(conn, 404, "")
    end
  end

  defp route(conn, _vm_id), do: send_resp(conn, 404, "")

  defp reply(conn, {:ok, nil}), do: send_resp(conn, 204, "")
  defp reply(conn, {:ok, body}) when is_map(body), do: json(conn, 200, body)
  defp reply(conn, {:error, :too_large}), do: send_resp(conn, 413, "")
  defp reply(conn, {:error, :rate_limited}), do: send_resp(conn, 429, "")
  # The agent is stopping: the guest keeps the lines for the next one.
  defp reply(conn, {:error, :draining}), do: send_resp(conn, 503, "")
  defp reply(conn, {:error, :no_vm}), do: send_resp(conn, 404, "")
  defp reply(conn, {:error, _}), do: send_resp(conn, 422, "")

  defp read_limited(conn, max) do
    case read_body(conn, length: max, read_length: 65_536, read_timeout: 10_000) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _, conn} -> {:too_large, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
