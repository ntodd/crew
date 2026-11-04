defmodule CrewCache.FakeParent do
  @moduledoc """
  A parent cache (§15.7) for tests: HTTPS on `localhost` with its own
  CA, serving `/v2/<prefix>/<repo>/(manifests|blobs)/<digest>` from a
  map. `mode/1` makes it fail (`{:status, n}`), stall before the first
  byte (`{:slow, ms}`) or serve wrong bytes (`:corrupt`). It records
  each request with its `Authorization`.
  """
  use Agent

  def start do
    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:namedCurve, :secp256r1}, digest: :sha256],
          intermediates: [],
          peer: [
            key: {:namedCurve, :secp256r1},
            digest: :sha256,
            extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"localhost"}]}]
          ]
        },
        client_chain: %{root: [], intermediates: [], peer: []}
      })

    {:ok, _} =
      Agent.start_link(fn -> %{objects: %{}, mode: :ok, requests: []} end, name: __MODULE__)

    {:ok, pid} =
      Bandit.start_link(
        plug: __MODULE__.Plug,
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        thousand_island_options: [
          transport_options: Keyword.take(server, [:cert, :key, :cacerts])
        ]
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    [root | _] = Keyword.fetch!(client, :cacerts)

    %{
      url: "https://localhost:#{port}",
      ca_pem: :public_key.pem_encode([{:Certificate, root, :not_encrypted}])
    }
  end

  def put(objects), do: Agent.update(__MODULE__, &%{&1 | objects: Map.merge(&1.objects, objects)})
  def mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  defmodule Plug do
    @moduledoc false
    import Elixir.Plug.Conn

    def init(opts), do: opts

    def call(conn, _) do
      state = Agent.get(CrewCache.FakeParent, & &1)
      auth = get_req_header(conn, "authorization") |> List.first()

      Agent.update(
        CrewCache.FakeParent,
        &%{&1 | requests: [%{path: conn.request_path, authorization: auth} | &1.requests]}
      )

      digest = List.last(conn.path_info)

      case {state.mode, Map.fetch(state.objects, digest)} do
        {{:status, status}, _} ->
          send_resp(conn, status, "")

        {{:slow, ms}, {:ok, body}} ->
          Process.sleep(ms)
          send_resp(conn, 200, body)

        {:corrupt, {:ok, <<first, rest::binary>>}} ->
          send_resp(conn, 200, <<Bitwise.bxor(first, 1), rest::binary>>)

        {_, {:ok, body}} ->
          conn
          |> put_resp_content_type("application/vnd.oci.image.manifest.v1+json", nil)
          |> send_resp(200, body)

        {_, :error} ->
          send_resp(conn, 404, "")
      end
    end
  end
end
