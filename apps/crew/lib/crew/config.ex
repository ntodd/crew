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
end
