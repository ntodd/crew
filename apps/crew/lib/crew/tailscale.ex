defmodule Crew.Tailscale do
  @moduledoc """
  Tailscale auth keys for Flatcar boxes (§5.3, Foreman's): with an OAuth
  client (CREW_TAILSCALE_CLIENT_ID and CREW_TAILSCALE_CLIENT_SECRET,
  scope `auth_keys`, allowed to tag `tag:crew-box`), the control plane
  mints each box a single-use, pre-authorized key tagged `tag:crew-box`
  that expires with its join token. Without one, Add box takes a key the
  admin made in Tailscale's console.
  """

  @api "https://api.tailscale.com"
  @tag "tag:crew-box"

  @doc "The OAuth client, or nil when there's none."
  def creds do
    config = Application.get_env(:crew, :tailscale, %{}) || %{}

    if is_binary(config[:client_id]) and config[:client_id] != "" and
         is_binary(config[:client_secret]) and config[:client_secret] != "",
       do: %{
         client_id: config.client_id,
         client_secret: config.client_secret,
         tailnet: config[:tailnet] || "-"
       },
       else: nil
  end

  def configured?, do: creds() != nil

  def box_tag, do: @tag

  @doc """
  A single-use, pre-authorized key tagged `tag:crew-box` for the box
  `name`, expiring in `expiry_seconds`.
  """
  def create_box_auth_key(name, expiry_seconds) do
    with creds when is_map(creds) <- creds() || {:error, :not_configured},
         {:ok, token} <- access_token(creds) do
      body = %{
        capabilities: %{
          devices: %{
            create: %{reusable: false, ephemeral: false, preauthorized: true, tags: [@tag]}
          }
        },
        expirySeconds: expiry_seconds,
        description: String.slice("crew box #{name}", 0, 50)
      }

      case Req.post(req(),
             url: "/api/v2/tailnet/#{URI.encode_www_form(creds.tailnet)}/keys",
             auth: {:bearer, token},
             json: body
           ) do
        {:ok, %{status: 200, body: %{"key" => key}}} when is_binary(key) -> {:ok, key}
        other -> unexpected(other)
      end
    end
  end

  # A token per mint: keys are minted once per join token, so there's
  # little to save by keeping one.
  defp access_token(creds) do
    case Req.post(req(),
           url: "/api/v2/oauth/token",
           form: [
             client_id: creds.client_id,
             client_secret: creds.client_secret,
             grant_type: "client_credentials"
           ]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      other ->
        unexpected(other)
    end
  end

  defp req do
    Req.new(base_url: @api, retry: :transient, max_retries: 2)
    |> Req.merge(Application.get_env(:crew, :tailscale_req_options, []))
  end

  defp unexpected({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:http, status, if(is_map(body), do: body["message"])}}

  defp unexpected({:error, exception}), do: {:error, Exception.message(exception)}
end
