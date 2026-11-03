defmodule CrewAgent.Identity do
  @moduledoc """
  The agent's id and ed25519 private key, in
  `${CREW_DATA_DIR}/agent/identity.json` (0600, §10.1). Created once by
  enrolling with a single-use join token.
  """

  alias CrewProtocol.Auth

  @enforce_keys [:agent_id, :private_key]
  defstruct [:agent_id, :private_key]

  @type t :: %__MODULE__{agent_id: String.t(), private_key: binary()}

  @spec load(Path.t()) :: {:ok, t()} | :none | {:error, term()}
  def load(agent_dir) do
    path = path(agent_dir)

    # Anything wrong with the file is an error the connection retries on,
    # not a crash: crashing here would restart-loop the whole agent.
    case File.read(path) do
      {:ok, json} ->
        with {:ok, %{"agent_id" => id, "private_key" => key}}
             when is_binary(id) and id != "" and is_binary(key) <- JSON.decode(json),
             {:ok, key} when byte_size(key) == 32 <- Base.decode64(key) do
          remember(key)
          {:ok, %__MODULE__{agent_id: id, private_key: key}}
        else
          _ -> {:error, "#{path} is damaged; re-enroll this box with a new join token"}
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Registers this agent's new public key with the control plane, using a
  join token, and saves the identity.
  """
  @spec enroll(CrewAgent.Config.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def enroll(config, opts \\ []) do
    # The token goes nowhere a ws:// URL would send it in the clear.
    case CrewAgent.Config.check_url(config) do
      :ok -> do_enroll(config, opts)
      {:error, message} -> {:error, message}
    end
  end

  defp do_enroll(config, opts) do
    {public, private} = Auth.generate_keypair()

    body = %{
      "join_token" => config.join_token,
      "public_key" => Base.encode64(public),
      "os" => to_string(elem(:os.type(), 1)),
      "agent_version" => version()
    }

    url = enroll_url(config.url)

    case Req.post(
           [url: url, json: body, retry: false, redirect: false] ++
             Keyword.get(opts, :req_options, [])
         ) do
      {:ok, %Req.Response{status: 201, body: %{"agent_id" => agent_id}}} ->
        identity = %__MODULE__{agent_id: agent_id, private_key: private}
        :ok = save(CrewAgent.Config.agent_dir(config), identity)
        {:ok, identity}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "enrollment refused (HTTP #{status}): #{error_message(body)}"}

      {:error, exception} ->
        {:error, "couldn't reach #{url}: #{Exception.message(exception)}"}
    end
  end

  defp error_message(%{"error" => message}), do: message
  defp error_message(_), do: "no details"

  @doc """
  The key as the identity file holds it, for `CrewAgent.Redactor` to
  scrub from everything the agent sends: a compose error can quote any
  file the agent can read, this one included.
  """
  @spec secrets() :: [String.t()]
  def secrets, do: :persistent_term.get({__MODULE__, :secrets}, [])

  defp remember(key), do: :persistent_term.put({__MODULE__, :secrets}, [Base.encode64(key)])

  def save(agent_dir, %__MODULE__{} = identity) do
    remember(identity.private_key)
    File.mkdir_p!(agent_dir)
    File.chmod!(agent_dir, 0o700)

    json =
      JSON.encode!(%{
        "agent_id" => identity.agent_id,
        "private_key" => Base.encode64(identity.private_key)
      })

    CrewAgent.SafeFS.write_atomic(path(agent_dir), json, 0o600)
  end

  defp path(agent_dir), do: Path.join(agent_dir, "identity.json")

  @doc "The enrollment URL for the socket URL `wss://host/agent/websocket`."
  def enroll_url(socket_url) do
    uri = URI.parse(socket_url)
    scheme = if uri.scheme in ["wss", "https"], do: "https", else: "http"
    URI.to_string(%{uri | scheme: scheme, path: "/api/agents/enroll", query: nil})
  end

  def hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  def version, do: :crew_agent |> Application.spec(:vsn) |> to_string()
end
