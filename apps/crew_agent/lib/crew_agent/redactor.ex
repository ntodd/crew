defmodule CrewAgent.Redactor do
  @moduledoc """
  Keeps the JIT config and guest tokens out of everything the agent
  logs or reports (§6.3, §10.1). Commands already mask them when
  inspected (`CrewProtocol.Command`); this is for maps and text built
  from them.
  """

  @doc "Removes secret keys from a map, at any depth."
  def redact(map) when is_map(map), do: CrewProtocol.Command.redact(map)
  def redact(other), do: other

  @doc "Masks known secret values in text (a JIT config or a guest token)."
  def redact_text(text, secrets) when is_binary(text) do
    Enum.reduce(secrets, text, fn
      secret, acc when is_binary(secret) and byte_size(secret) >= 16 ->
        String.replace(acc, secret, "[redacted]")

      _, acc ->
        acc
    end)
  end
end
