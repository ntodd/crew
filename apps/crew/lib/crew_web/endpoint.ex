defmodule CrewWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :crew

  # Signed and encrypted. The Secure flag is added at runtime
  # (CREW_SECURE_COOKIES, on in production).
  @session_options [
    store: :cookie,
    key: "_crew_key",
    signing_salt: "oxz9an9c",
    encryption_salt: "ZqJ3p1fU",
    same_site: "Lax",
    http_only: true,
    max_age: 30 * 24 * 60 * 60
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Agents dial in here. They aren't browsers, so there's no origin to
  # check: each connect is authenticated by a signed header instead, and
  # carries no cookies a cross-site page could ride on.
  # sobelow_skip ["Config.CSWH"]
  socket "/agent", CrewWeb.AgentSocket,
    websocket: [connect_info: [:x_headers, :peer_data], check_origin: false, timeout: 60_000],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :crew,
    gzip: not code_reloading?,
    only: CrewWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :crew
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug :force_ssl
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []}

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    length: 2_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug :session
  plug CrewWeb.Router

  @doc false
  # Health checks run every few seconds; logging each one drowns the log.
  def log_level(%Plug.Conn{path_info: ["healthz"]}), do: false
  def log_level(_conn), do: :info

  # Redirects to HTTPS unless the request arrived over it (directly, or
  # through `tailscale serve`, which sets X-Forwarded-Proto) or from
  # loopback. On in production (CREW_FORCE_SSL).
  defp force_ssl(conn, _opts) do
    if Application.get_env(:crew, :force_ssl, false) do
      Plug.SSL.call(
        conn,
        Plug.SSL.init(rewrite_on: [:x_forwarded_proto], exclude: ["localhost", "127.0.0.1"])
      )
    else
      conn
    end
  end

  defp session(conn, _opts) do
    opts =
      Keyword.put(
        @session_options,
        :secure,
        Application.get_env(:crew, :secure_cookies, false)
      )

    Plug.Session.call(conn, Plug.Session.init(opts))
  end
end
