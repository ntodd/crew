defmodule CrewCache.Upstream do
  @moduledoc """
  Requests to a compiled host's real upstream, as the cache's own
  anonymous client (§15.3):

  - **The client's `Authorization` is never sent.** Requests carry only
    the cache's anonymous token for the repository, fetched from the
    host's **compiled** realm (the challenge's `service` is used; its
    `realm` isn't) and cached until it expires.
  - **Redirects** (blob storage) are followed up to 5 times, to https
    only, without the token once the origin changes.
  - **Every connection goes through `CrewCache.Dial`**, so the upstream
    and every redirect target are resolved by the cache and refused in
    blocked4 or site4. One Finch pool per host.
  - Nothing here logs a header or a token.

  A `:sink` gets the final 2xx response's headers and body as they
  arrive; without one the body is collected, up to `:max_body`.
  """

  alias CrewCache.Config
  alias CrewCache.Upstream.Memo

  @finch CrewCache.Finch
  @max_redirects 5
  @redirects [301, 302, 303, 307, 308]
  @error_body_max 64 * 1024

  @type host :: %{host: String.t(), upstream: String.t(), realm: String.t() | nil}
  @type sink :: {(term, term -> {:cont, term} | {:halt, term}), term}

  @doc """
  `method` (`"GET"` or `"HEAD"`) `/v2/<repo>/<rest>` on `host`'s
  upstream. Returns `{:ok, %{status, headers, body, sink: acc}}` or
  `{:error, reason}`.
  """
  def request(host, repo, method, rest, opts \\ []) do
    url = origin(host.upstream) <> "/v2/" <> repo <> "/" <> rest
    key = {host.host, repo}

    auth =
      case Memo.token(key) do
        {:ok, token} -> [{"authorization", "Bearer " <> token}]
        :error -> []
      end

    case send_following(method, url, Keyword.get(opts, :headers, []), auth, opts) do
      {:ok, %{status: 401} = resp} when host.realm != nil ->
        with {:ok, token} <- token(host, repo, resp) do
          send_following(method, url, Keyword.get(opts, :headers, []), bearer(token), opts)
        end

      other ->
        other
    end
  end

  defp bearer(token), do: [{"authorization", "Bearer " <> token}]

  # -- tokens -------------------------------------------------------------------

  defp token(host, repo, resp) do
    params = challenge(resp.headers)
    service = Map.get(params, "service", host.upstream)
    query = URI.encode_query(%{"service" => service, "scope" => "repository:#{repo}:pull"})
    url = rewrite(host.realm) <> "?" <> query

    with {:ok, %{status: 200, body: body}} <- send_following("GET", url, [], [], max_body: 16_384),
         {:ok, %{} = json} <- Jason.decode(body),
         token when is_binary(token) and token != "" <- json["token"] || json["access_token"] do
      ttl = if is_integer(json["expires_in"]), do: json["expires_in"], else: 60
      Memo.put_token({host.host, repo}, token, (ttl - min(10, div(ttl, 2))) * 1000)
      {:ok, token}
    else
      {:ok, %{status: status}} -> {:error, {:token_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :bad_token_response}
    end
  end

  defp challenge(headers) do
    case List.keyfind(headers, "www-authenticate", 0) do
      {_, "Bearer " <> params} ->
        for [_, k, v] <- Regex.scan(~r/(\w+)="([^"]*)"/, params), into: %{}, do: {k, v}

      _ ->
        %{}
    end
  end

  # -- origins --------------------------------------------------------------------

  @doc "The origin for a compiled upstream (tests map these to a fake)."
  def origin(upstream), do: "https://" <> Map.get(Config.get().origins, upstream, upstream)

  defp rewrite(url) do
    uri = URI.parse(url)
    origin(uri.host) <> (uri.path || "")
  end

  # -- sending ----------------------------------------------------------------------

  defp send_following(method, url, headers, auth, opts, hops \\ 0) do
    with {:ok, resp} <- send_one(method, url, headers ++ auth, opts) |> drop_sink() do
      location = header(resp.headers, "location")

      cond do
        resp.status not in @redirects or location == nil ->
          {:ok, resp}

        hops >= @max_redirects ->
          {:error, :too_many_redirects}

        true ->
          next = URI.merge(url, location) |> URI.to_string()
          auth = if same_origin?(url, next), do: auth, else: []

          if URI.parse(next).scheme == "https",
            do: send_following(method, next, headers, auth, opts, hops + 1),
            else: {:error, :insecure_redirect}
      end
    end
  end

  defp same_origin?(a, b) do
    {ua, ub} = {URI.parse(a), URI.parse(b)}
    {ua.scheme, ua.host, ua.port} == {ub.scheme, ub.host, ub.port}
  end

  defp drop_sink({:error, error, _sink}), do: {:error, error}
  defp drop_sink(other), do: other

  @doc """
  One request, no redirects or tokens: `{:ok, %{status, headers, body,
  sink}}` or `{:error, reason, sink_acc}`, so a caller can tell whether
  its sink had started. `:finch` picks the pool (the parent has its
  own).
  """
  def send_one(method, url, headers, opts) do
    request = Finch.build(method, url, [{"user-agent", "crew-cache"} | headers])
    sink = Keyword.get(opts, :sink)
    max_body = Keyword.get(opts, :max_body, 4 * 1024 * 1024)
    acc = %{status: nil, headers: [], body: [], size: 0, sink: sink && elem(sink, 1), over: false}

    result =
      Finch.stream_while(
        request,
        Keyword.get(opts, :finch, @finch),
        acc,
        &step(&1, &2, sink, max_body),
        receive_timeout: Keyword.get(opts, :receive_timeout, 30_000),
        pool_timeout: 10_000
      )

    case result do
      {:ok, %{over: true} = acc} ->
        {:error, :body_too_large, acc.sink}

      {:ok, acc} ->
        {:ok,
         %{
           status: acc.status,
           headers: acc.headers,
           body: IO.iodata_to_binary(Enum.reverse(acc.body)),
           sink: acc.sink
         }}

      {:error, error, acc} ->
        {:error, error, acc.sink}
    end
  end

  defp step({:status, status}, acc, _sink, _max), do: {:cont, %{acc | status: status}}

  defp step({:headers, headers}, acc, sink, _max) do
    headers = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)
    acc = %{acc | headers: acc.headers ++ headers}

    if sinking?(acc, sink) do
      {fun, _} = sink
      wrap(fun.({:headers, acc.status, acc.headers}, acc.sink), acc)
    else
      {:cont, acc}
    end
  end

  defp step({:data, data}, acc, sink, max) do
    cond do
      sinking?(acc, sink) ->
        {fun, _} = sink
        wrap(fun.({:data, data}, acc.sink), acc)

      acc.size + byte_size(data) > if(acc.status in 200..299, do: max, else: @error_body_max) ->
        {:halt, %{acc | over: true}}

      true ->
        {:cont, %{acc | body: [data | acc.body], size: acc.size + byte_size(data)}}
    end
  end

  defp step(_other, acc, _sink, _max), do: {:cont, acc}

  defp sinking?(acc, sink), do: sink != nil and acc.status in 200..299

  defp wrap({:cont, sink_acc}, acc), do: {:cont, %{acc | sink: sink_acc}}
  defp wrap({:halt, sink_acc}, acc), do: {:halt, %{acc | sink: sink_acc}}

  @doc "A response header, lowercase name."
  def header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  @doc "An `Accept` header as the micro-cache keys it: types without parameters, sorted."
  def normalise_accept(nil), do: ""

  def normalise_accept(accept) do
    accept
    |> String.split(",")
    |> Enum.map(&(&1 |> String.split(";") |> hd() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(",")
  end
end
