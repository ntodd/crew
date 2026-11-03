defmodule CrewGuest.FakeAPI do
  @moduledoc """
  A fake Guest API (§13.4) for tests: Bandit on a random loopback port,
  recording every request and validating bodies with `CrewProtocol.Guest`,
  the same code the agent uses.

  By default:
  - `GET /v1/payload` answers the configured payload once, then 410;
  - the POSTs answer 204;
  - `GET /v1/control` is held until `request_stop/1` (or 30 s, then 204).

  Scripted answers (`respond/3`) take precedence. Each is one of
  `{status, json_or_nil}`, `:drop` (the connection is killed, so the
  client sees a transport error) or `{:delay, ms, answer}`. The last
  scripted answer for a path is kept and repeats.
  """

  use GenServer

  alias CrewProtocol.Guest

  @life {0, 9_999_999_999_999}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def url(api), do: GenServer.call(api, :url)
  def port(api), do: GenServer.call(api, :port)

  @doc "Scripts the answers for `path`."
  def respond(api, path, answers) when is_list(answers),
    do: GenServer.call(api, {:respond, path, answers})

  @doc "Every request is dropped while down."
  def set_down(api, down?), do: GenServer.call(api, {:down, down?})

  @doc "Answers held control polls, and every later response, with `{\"stop\": true}`."
  def request_stop(api), do: GenServer.call(api, :request_stop)

  @doc "Recorded requests, oldest first."
  def requests(api), do: GenServer.call(api, :requests)
  def requests(api, path), do: Enum.filter(requests(api), &(&1.path == path))

  @doc "Requests that got a 2xx answer."
  def delivered(api, path), do: Enum.filter(requests(api, path), &(&1.status in 200..299))

  @doc "The states delivered, in order."
  def states(api), do: Enum.map(delivered(api, "/v1/state"), & &1.cast.state)

  @doc "Every log line delivered, in order, as `CrewProtocol.Guest.cast_log_line/2` cleans it."
  def log_lines(api), do: Enum.flat_map(delivered(api, "/v1/log"), & &1.cast.lines)

  def log_texts(api), do: Enum.map(log_lines(api), & &1.text)

  @doc "The last steps delivered."
  def last_steps(api) do
    case delivered(api, "/v1/steps") do
      [] -> []
      reqs -> List.last(reqs).cast
    end
  end

  # Server

  @impl true
  def init(opts) do
    state = %{
      token: Keyword.get(opts, :token, "t0ken"),
      payload: Keyword.get(opts, :payload),
      payload_served: false,
      scripts: %{},
      down: false,
      stop: false,
      holders: [],
      requests: [],
      port: nil
    }

    {:ok, server} =
      Bandit.start_link(
        plug: {CrewGuest.FakeAPI.Plug, self()},
        ip: :loopback,
        port: Keyword.get(opts, :port, 0),
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, %{state | port: port}}
  end

  @impl true
  def handle_call(:url, _from, s), do: {:reply, "http://127.0.0.1:#{s.port}", s}
  def handle_call(:port, _from, s), do: {:reply, s.port, s}

  def handle_call({:respond, path, answers}, _from, s),
    do: {:reply, :ok, put_in(s.scripts[path], answers)}

  def handle_call({:down, down?}, _from, s), do: {:reply, :ok, %{s | down: down?}}
  def handle_call(:requests, _from, s), do: {:reply, Enum.reverse(s.requests), s}

  def handle_call(:request_stop, _from, s) do
    for holder <- s.holders, do: send(holder, {:release, {200, %{"stop" => true}}})
    {:reply, :ok, %{s | stop: true, holders: []}}
  end

  def handle_call({:request, req, holder}, _from, s) do
    {answer, s} = answer(req, s)
    req = Map.merge(req, %{status: status_of(answer), cast: cast(req)})
    s = %{s | requests: [req | s.requests]}

    case answer do
      :hold -> {:reply, :hold, %{s | holders: [holder | s.holders]}}
      other -> {:reply, other, s}
    end
  end

  def handle_call({:released, holder}, _from, s),
    do: {:reply, :ok, %{s | holders: List.delete(s.holders, holder)}}

  defp answer(_req, %{down: true} = s), do: {:drop, s}

  defp answer(req, s) do
    cond do
      req.auth != "Bearer " <> s.token ->
        {{401, nil}, s}

      Map.has_key?(s.scripts, req.path) ->
        scripted(req.path, s)

      true ->
        default(req, s)
    end
  end

  defp scripted(path, s) do
    case s.scripts[path] do
      [only] -> {only, s}
      [next | rest] -> {next, put_in(s.scripts[path], rest)}
    end
  end

  defp default(%{path: "/v1/payload"}, %{payload_served: false, payload: p} = s)
       when not is_nil(p),
       do: {{200, p}, %{s | payload_served: true}}

  defp default(%{path: "/v1/payload"}, s), do: {{410, nil}, s}
  defp default(%{path: "/v1/control"}, %{stop: true} = s), do: {{200, %{"stop" => true}}, s}
  defp default(%{path: "/v1/control"}, s), do: {:hold, s}
  defp default(_req, %{stop: true} = s), do: {{200, %{"stop" => true}}, s}
  defp default(_req, s), do: {{204, nil}, s}

  defp status_of({:delay, _ms, answer}), do: status_of(answer)
  defp status_of({status, _}), do: status
  defp status_of(:hold), do: :held
  defp status_of(:drop), do: :dropped

  defp cast(%{path: "/v1/state", json: json}), do: ok(Guest.cast_state(json, @life))
  defp cast(%{path: "/v1/steps", json: json}), do: ok(Guest.cast_steps(json, @life))
  defp cast(%{path: "/v1/metrics", json: json}), do: ok(Guest.cast_metrics(json, @life))

  defp cast(%{path: "/v1/log", raw: raw}) do
    {:ok, lines, skipped} = Guest.parse_ndjson(raw, @life)
    %{lines: lines, skipped: skipped}
  end

  defp cast(_req), do: nil

  defp ok({:ok, v}), do: v
  defp ok({:error, reason}), do: {:invalid, reason}

  defmodule Plug do
    @moduledoc false
    import Elixir.Plug.Conn

    def init(api), do: api

    def call(conn, api) do
      {:ok, raw, conn} = read_body(conn, length: 64_000_000)

      req = %{
        method: conn.method,
        path: conn.request_path,
        auth: conn |> get_req_header("authorization") |> List.first(),
        content_type: conn |> get_req_header("content-type") |> List.first(),
        raw: raw,
        bytes: byte_size(raw),
        json: decode(raw),
        at: System.monotonic_time(:millisecond)
      }

      reply(conn, api, GenServer.call(api, {:request, req, self()}))
    end

    defp reply(conn, api, :hold) do
      receive do
        {:release, answer} -> reply(conn, api, answer)
      after
        30_000 ->
          GenServer.call(api, {:released, self()})
          send_resp(conn, 204, "")
      end
    end

    defp reply(_conn, _api, :drop), do: Process.exit(self(), :kill)

    defp reply(conn, api, {:delay, ms, answer}) do
      Process.sleep(ms)
      reply(conn, api, answer)
    end

    defp reply(conn, _api, {status, nil}), do: send_resp(conn, status, "")

    defp reply(conn, _api, {status, body}) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end

    defp decode(""), do: nil

    defp decode(raw) do
      case Jason.decode(raw) do
        {:ok, v} -> v
        _ -> nil
      end
    end
  end
end
