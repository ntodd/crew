defmodule CrewAgent.Cache do
  @moduledoc """
  The box's registry cache (§15), through its management endpoint. The
  CA root it reports goes into every guest's payload, as the trust
  anchor for the cache's certificates.
  """

  alias CrewAgent.Config

  @doc "The cache's root certificate, or `{:error, reason}` when there's no cache."
  def ca_pem(%Config{cache_mgmt_url: nil}), do: {:error, :no_cache}

  def ca_pem(%Config{cache_mgmt_url: url, cache_mgmt_token: token}) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []

    case Req.get(url <> "/ca.pem", headers: headers, retry: false, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: pem}} when is_binary(pem) -> {:ok, pem}
      other -> {:error, other}
    end
  rescue
    e -> {:error, e}
  end
end
