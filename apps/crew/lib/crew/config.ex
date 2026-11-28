defmodule Crew.Config do
  @moduledoc "Deployment settings read from the application environment."

  @doc "The running control plane's version (the release tag for CI-built images)."
  def version, do: to_string(Application.spec(:crew, :vsn))

  @doc """
  The control plane's external base URL, e.g. https://crew.tail1234.ts.net:
  CREW_BASE_URL if set, else the public host from setup, else the
  endpoint's own URL (development).
  """
  def base_url do
    case Application.get_env(:crew, :base_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        case Crew.Settings.public_host() do
          host when is_binary(host) -> "https://" <> host
          nil -> endpoint_url()
        end
    end
  end

  defp endpoint_url do
    config = Application.get_env(:crew, CrewWeb.Endpoint, [])
    url = config[:url] || []
    scheme = url[:scheme] || "http"
    host = url[:host] || "localhost"
    port = url[:port] || get_in(config, [:http, :port]) || 4000

    default_port? = (scheme == "https" and port == 443) or (scheme == "http" and port == 80)
    if default_port?, do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"
  end

  @doc "The release signing public key (32 raw bytes), from CREW_RELEASE_PUBLIC_KEY (base64)."
  def release_public_key do
    with key when is_binary(key) and key != "" <- Application.get_env(:crew, :release_public_key),
         {:ok, <<_::binary-size(32)>> = raw} <- Base.decode64(String.trim(key)) do
      raw
    else
      _ -> nil
    end
  end

  def release_key_fingerprint do
    case release_public_key() do
      nil -> nil
      key -> CrewProtocol.Auth.fingerprint(key)
    end
  end

  @doc "CREW_DEV: allows the null driver and ws:// agents (§21.1)."
  def dev?, do: Application.get_env(:crew, :dev, false) == true

  @doc """
  `CREW_TRUSTED_PROXIES`: comma-separated CIDRs, as `[{address, bits}]`,
  and `gateway`, the default gateway of the network Crew is on (in a
  container, the bridge's), as a /32. Raises on anything else, so a typo
  fails at boot.
  """
  @spec parse_cidrs!(String.t(), keyword()) :: [{:inet.ip_address(), non_neg_integer()}]
  def parse_cidrs!(value, opts \\ []) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_cidr!(&1, opts))
  end

  # `routes:` stands in for /proc/net/route's contents in the tests.
  defp parse_cidr!("gateway", opts),
    do: {default_gateway!(Keyword.get_lazy(opts, :routes, &read_routes/0)), 32}

  defp parse_cidr!(cidr, _opts), do: parse_cidr!(cidr)

  defp parse_cidr!(cidr) do
    with [addr, bits] <- String.split(cidr, "/", parts: 2),
         true <- bits =~ ~r/\A\d{1,3}\z/,
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(addr)),
         false <- mapped?(ip),
         n = String.to_integer(bits),
         true <- n <= if(tuple_size(ip) == 4, do: 32, else: 128) do
      {ip, n}
    else
      _ ->
        raise ArgumentError,
              "CREW_TRUSTED_PROXIES: #{inspect(cidr)} isn't a CIDR (like 172.16.0.0/12; an " <>
                "IPv4 range in its IPv4 form) or gateway"
    end
  end

  defp mapped?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: true
  defp mapped?(_), do: false

  defp read_routes do
    case File.read("/proc/net/route") do
      {:ok, body} -> body
      {:error, _} -> ""
    end
  end

  # /proc/net/route: the default route (destination and mask 0) has the
  # gateway, as a little-endian hex IPv4 address.
  defp default_gateway!(routes) do
    with [hex | _] <-
           for(
             line <- String.split(routes, "\n"),
             [_iface, "00000000", gw, _flags, _ref, _use, _metric, "00000000" | _] <-
               [String.split(line)],
             gw != "00000000",
             do: gw
           ),
         {n, ""} <- Integer.parse(hex, 16) do
      <<a, b, c, d>> = <<n::little-32>>
      {a, b, c, d}
    else
      _ -> raise ArgumentError, "CREW_TRUSTED_PROXIES: gateway, but there's no default route"
    end
  end

  @doc "The configured ranges, parsed once per value (`Crew.Application` checks them at boot, `CrewWeb.ClientIP` uses them)."
  def trusted_proxies do
    value = Application.get_env(:crew, :trusted_proxies, "")

    case :persistent_term.get({__MODULE__, value}, nil) do
      nil ->
        cidrs = parse_cidrs!(value)
        :persistent_term.put({__MODULE__, value}, cidrs)
        cidrs

      cidrs ->
        cidrs
    end
  end
end
