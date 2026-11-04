defmodule CrewImage.Smoke.GuestAPI do
  @moduledoc """
  A fake guest API (§13.4) for one VM, as the agent serves it on the VM's
  `guest.sock`. It records what crew-guest sends, with the time each
  request arrived (monotonic ms), and validates bodies with
  `CrewProtocol.Guest`, as the agent does.

  - `GET /v1/payload`: the payload once, then 410. With `payload:
    :withhold`, 503 every time (crew-guest keeps asking for 60 s).
  - `POST /v1/state`, `/v1/log`, `/v1/steps`, `/v1/metrics`: 204, or
    `{"stop": true}` once a stop is asked for.
  - `GET /v1/control`: held for `control_hold_ms` (30 s), then 204, or
    `{"stop": true}` as soon as `request_stop/1` is called.

  Any other token is 401.
  """
  use GenServer

  alias CrewProtocol.Guest

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc "Everything recorded, oldest first: `%{at: ms, kind: atom, data: term}`."
  def events(api), do: GenServer.call(api, :events)

  def request_stop(api), do: GenServer.call(api, :request_stop)

  @doc false
  def handle(api, request), do: GenServer.call(api, {:handle, request}, :infinity)

  @doc false
  def wait_stop(api), do: GenServer.call(api, :wait_stop, :infinity)

  @impl true
  def init(opts) do
    {:ok,
     %{
       token: Keyword.fetch!(opts, :token),
       payload: Keyword.fetch!(opts, :payload),
       served: false,
       stop: false,
       waiters: [],
       hold: Keyword.get(opts, :control_hold_ms, 30_000),
       started: System.monotonic_time(:millisecond),
       events: []
     }}
  end

  @impl true
  def handle_call(:events, _from, s), do: {:reply, Enum.reverse(s.events), s}

  def handle_call(:request_stop, _from, s) do
    for w <- s.waiters, do: GenServer.reply(w, :stop)
    {:reply, :ok, %{s | stop: true, waiters: []}}
  end

  def handle_call(:wait_stop, _from, %{stop: true} = s), do: {:reply, :stop, s}

  def handle_call(:wait_stop, from, s) do
    Process.send_after(self(), {:control_timeout, from}, s.hold)
    {:noreply, %{s | waiters: [from | s.waiters]}}
  end

  def handle_call({:handle, {token, _, _, _}}, _from, %{token: want} = s) when token != want,
    do: {:reply, {401, nil}, s}

  def handle_call({:handle, {_token, method, path, body}}, _from, s) do
    {reply, s} = route(method, path, body, s)
    {:reply, reply, s}
  end

  @impl true
  def handle_info({:control_timeout, from}, s) do
    if from in s.waiters do
      GenServer.reply(from, :timeout)
      {:noreply, %{s | waiters: List.delete(s.waiters, from)}}
    else
      {:noreply, s}
    end
  end

  defp route("GET", "/v1/payload", _body, %{payload: :withhold} = s),
    do: {{503, nil}, record(s, :payload_withheld, nil)}

  defp route("GET", "/v1/payload", _body, %{served: false} = s),
    do: {{200, s.payload}, record(%{s | served: true}, :payload, nil)}

  defp route("GET", "/v1/payload", _body, s), do: {{410, nil}, record(s, :payload_refetch, nil)}

  defp route("POST", "/v1/state", body, s) do
    with {:ok, map} <- Jason.decode(body),
         {:ok, state} <- Guest.cast_state(map, life(s)) do
      {ok(s), record(s, :state, state)}
    else
      _ -> {{422, nil}, record(s, :bad_request, {"/v1/state", body})}
    end
  end

  defp route("POST", "/v1/log", body, s) do
    {:ok, lines, _skipped} = Guest.parse_ndjson(body, life(s))
    {ok(s), record(s, :log, lines)}
  end

  defp route("POST", "/v1/steps", body, s) do
    case Jason.decode(body) do
      {:ok, map} -> {ok(s), record(s, :steps, Guest.cast_steps(map, life(s)))}
      _ -> {{422, nil}, s}
    end
  end

  defp route("POST", "/v1/metrics", body, s) do
    case Jason.decode(body) do
      {:ok, map} -> {ok(s), record(s, :metrics, Guest.cast_metrics(map, life(s)))}
      _ -> {{422, nil}, s}
    end
  end

  defp route("GET", "/v1/control", _body, s), do: {:control, record(s, :control, nil)}
  defp route(_method, path, _body, s), do: {{404, nil}, record(s, :unknown, path)}

  defp ok(%{stop: true}), do: {200, %{"stop" => true}}
  defp ok(_s), do: {204, nil}

  defp record(s, kind, data),
    do: %{
      s
      | events: [%{at: System.monotonic_time(:millisecond), kind: kind, data: data} | s.events]
    }

  defp life(s) do
    now = System.system_time(:millisecond)
    {now - (System.monotonic_time(:millisecond) - s.started), now}
  end

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    import Elixir.Plug.Conn

    alias CrewImage.Smoke.GuestAPI

    @impl true
    def init(api), do: api

    @impl true
    def call(conn, api) do
      token =
        case get_req_header(conn, "authorization") do
          ["Bearer " <> t] -> t
          _ -> nil
        end

      {:ok, body, conn} = read_body(conn, length: 2_000_000)

      case GuestAPI.handle(api, {token, conn.method, conn.request_path, body}) do
        :control -> control(conn, api)
        {status, nil} -> send_resp(conn, status, "")
        {status, json} -> json(conn, status, json)
      end
    end

    defp control(conn, api) do
      case GuestAPI.wait_stop(api) do
        :stop -> json(conn, 200, %{"stop" => true})
        :timeout -> send_resp(conn, 204, "")
      end
    end

    defp json(conn, status, map) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(map))
    end
  end
end
