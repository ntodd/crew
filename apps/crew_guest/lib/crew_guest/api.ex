defmodule CrewGuest.API do
  @moduledoc """
  The client for the agent's guest API (§13.4).

  Every request carries `Authorization: Bearer <token>`. Any response whose
  body is `{"stop": true}` calls `:on_stop`, whichever endpoint it came
  from (§13.5 step 11), before the result is returned.

  Results are `{:ok, status}` for a 2xx, `{:error, {:status, status}}` for
  anything else, and `{:error, exception}` when the request didn't get an
  answer. Retrying is the caller's business: Req's own retry is off.
  """

  @derive {Inspect, except: [:token]}
  defstruct [
    :base_url,
    :token,
    on_stop: nil,
    finch: CrewGuest.Finch,
    # The agent's read timeout is 10 s.
    receive_timeout: 10_000,
    # The control poll is held for up to 30 s.
    control_timeout: 40_000
  ]

  @type t :: %__MODULE__{}
  @type result :: {:ok, pos_integer()} | {:error, {:status, pos_integer()} | Exception.t()}

  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc "A client for `config`'s API URL and token."
  def from_config(%CrewGuest.Config{} = config, opts \\ []) do
    new([base_url: config.api_url, token: config.token] ++ opts)
  end

  @doc "`GET /v1/payload`: the JIT config, the cache CA and the policy, once."
  @spec get_payload(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_payload(client, opts \\ []) do
    case request(client, :get, "/v1/payload", opts) do
      {:ok, 200, %{} = payload} -> {:ok, payload}
      {:ok, 200, _} -> {:error, :bad_payload}
      {:ok, status, _} -> {:error, {:status, status}}
      {:error, _} = error -> error
    end
  end

  @spec post_state(t(), map()) :: result()
  def post_state(client, body), do: post_json(client, "/v1/state", body)

  @spec post_steps(t(), map()) :: result()
  def post_steps(client, body), do: post_json(client, "/v1/steps", body)

  @spec post_metrics(t(), map()) :: result()
  def post_metrics(client, body), do: post_json(client, "/v1/metrics", body)

  @doc "`POST /v1/log` with an NDJSON body (iodata)."
  @spec post_log(t(), iodata()) :: result()
  def post_log(client, ndjson) do
    client
    |> request(:post, "/v1/log",
      body: ndjson,
      headers: [{"content-type", "application/x-ndjson"}]
    )
    |> status_only()
  end

  @doc "`GET /v1/control`, the long poll: `:stop`, or `:continue` to poll again."
  @spec get_control(t()) :: {:ok, :stop | :continue} | {:error, term()}
  def get_control(client) do
    case request(client, :get, "/v1/control", receive_timeout: client.control_timeout) do
      {:ok, _status, %{"stop" => true}} -> {:ok, :stop}
      {:ok, status, _} when status in 200..299 -> {:ok, :continue}
      {:ok, status, _} -> {:error, {:status, status}}
      {:error, _} = error -> error
    end
  end

  defp post_json(client, path, body) do
    client
    |> request(:post, path,
      body: Jason.encode_to_iodata!(body),
      headers: [{"content-type", "application/json"}]
    )
    |> status_only()
  end

  defp status_only({:ok, status, _body}) when status in 200..299, do: {:ok, status}
  defp status_only({:ok, status, _body}), do: {:error, {:status, status}}
  defp status_only({:error, _} = error), do: error

  @doc false
  def request(client, method, path, opts \\ []) do
    {receive_timeout, opts} = Keyword.pop(opts, :receive_timeout, client.receive_timeout)

    req =
      Req.new(
        method: method,
        url: client.base_url <> path,
        auth: {:bearer, client.token},
        retry: false,
        redirect: false,
        decode_body: false,
        receive_timeout: receive_timeout,
        finch: [name: client.finch]
      )

    case Req.request(req, opts) do
      {:ok, %Req.Response{status: status, body: body}} ->
        body = decode(body)
        if stop?(body) and client.on_stop, do: client.on_stop.()
        {:ok, status, body}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp decode(""), do: nil

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode(body), do: body

  defp stop?(%{"stop" => true}), do: true
  defp stop?(_body), do: false
end
