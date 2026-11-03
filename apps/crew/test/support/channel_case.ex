defmodule CrewWeb.ChannelCase do
  @moduledoc "Tests for the agent socket and channel."

  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, false) and Crew.Repo.database() == "postgres"

    quote do
      use ExUnit.Case, async: unquote(async)

      import Phoenix.ChannelTest
      import CrewWeb.ChannelCase
      import Crew.Fixtures

      @endpoint CrewWeb.Endpoint

      setup tags do
        Crew.DataCase.setup_sandbox(tags)
        :ok
      end

      # Connects and joins as `box`'s agent.
      defp join_as(box) do
        {:ok, socket} = connect(CrewWeb.AgentSocket, %{}, connect_info: signed_connect_info(box))
        {:ok, _reply, socket} = subscribe_and_join(socket, "agent:#{box.id}", join_payload(box))
        socket
      end
    end
  end

  @doc "connect_info for a socket connect signed with `box`'s key."
  def signed_connect_info(box, opts \\ []) do
    headers = CrewProtocol.Auth.connect_headers(box.id, box.__private_key__, opts)

    %{
      x_headers: Enum.to_list(headers),
      peer_data: %{address: {127, 0, 0, 1}, port: 1, ssl_cert: nil}
    }
  end

  def join_payload(box, overrides \\ %{}) do
    CrewProtocol.Examples.join()
    |> Map.put("box_name", box.name)
    |> Map.merge(overrides)
  end
end
