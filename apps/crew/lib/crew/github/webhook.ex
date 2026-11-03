defmodule Crew.GitHub.Webhook do
  @moduledoc """
  Webhook signatures (§6.2): `X-Hub-Signature-256` is an HMAC-SHA256 of
  the raw body with the App's webhook secret, compared in constant time.
  """

  @doc "Verifies a delivery's signature header against its raw body."
  @spec verify(binary(), String.t() | nil, String.t() | nil) :: :ok | :error
  def verify(body, "sha256=" <> hex, secret)
      when is_binary(body) and is_binary(secret) and secret != "" and byte_size(hex) == 64 do
    if Plug.Crypto.secure_compare(sign(body, secret), "sha256=" <> String.downcase(hex)),
      do: :ok,
      else: :error
  end

  def verify(_body, _signature, _secret), do: :error

  @doc "The signature header GitHub would send for `body`."
  def sign(body, secret),
    do: "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

  @doc """
  What an event is about, for deduplicating its processing (§6.2): the
  job, or the run attempt (a re-run's attempt is a new object). Other
  events (installations and their repos) are each their own change, so
  they're keyed by their delivery.
  """
  def object_id("workflow_job", %{"workflow_job" => %{"id" => id}}, _delivery), do: to_string(id)

  def object_id("workflow_run", %{"workflow_run" => %{"id" => id} = run}, _delivery),
    do: "#{id}/#{run["run_attempt"] || 1}"

  def object_id(_event, _payload, delivery), do: delivery
end
