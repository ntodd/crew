defmodule CrewWeb.AgentSocket do
  @moduledoc """
  The socket agents dial in on (Foreman's). Every connect must carry
  headers signed with the agent's enrolled ed25519 key
  (`CrewProtocol.Auth`); stale clocks, unknown or revoked agents, bad
  signatures and replayed nonces are refused before a socket exists.
  """
  use Phoenix.Socket

  alias Crew.Agents.NonceCache
  alias Crew.RateLimit
  alias CrewProtocol.Auth
  alias CrewWeb.ClientIP

  require Logger

  channel "agent:*", CrewWeb.AgentChannel

  # Only refused connects count, per client, so junk can't lock out a
  # signed agent.
  @max_failures 600
  @window 60_000

  @impl true
  def connect(_params, socket, connect_info) do
    headers = Map.new(connect_info[:x_headers] || [], fn {k, v} -> {String.downcase(k), v} end)
    ip = ClientIP.from_connect_info(connect_info)
    key = "agent-connect-failed:#{ip}"

    with false <- RateLimit.exhausted?(key, @window, @max_failures),
         {:ok, %{agent_id: agent_id, nonce: nonce}} <-
           Auth.verify_connect_headers(headers, &Crew.Boxes.public_key/1),
         :ok <- NonceCache.check(nonce) do
      {:ok, socket |> assign(:box_id, agent_id) |> assign(:remote_ip, ip)}
    else
      true ->
        if RateLimit.failed(key, @window, @max_failures) == :first_over,
          do: Logger.warning("agent connects from #{ip} are rate limited")

        :error

      reason ->
        RateLimit.failed(key, @window, @max_failures)
        Logger.warning("refused an agent connect from #{ip}: #{inspect(reason)}")
        :error
    end
  end

  # Lets Crew.Boxes.revoke/2 (and re-enrollment) drop the socket.
  @impl true
  def id(socket), do: "agent_socket:#{socket.assigns.box_id}"
end
