defmodule CrewAgent.Redactor do
  @moduledoc """
  Keeps the JIT config and guest tokens out of everything the agent
  logs or reports (§6.3, §10.1). Commands already mask them when
  inspected (`CrewProtocol.Command`); this is for maps and text built
  from them.
  """

  @doc "Limit OTP diagnostics to operational state. Incoming messages and exception arguments can contain command payloads."
  def status(status, summarize) do
    status
    |> Map.replace_lazy(:state, summarize)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:queue, [])
    |> Map.replace(:log, [])
    |> Map.replace_lazy(:reason, &reason_class/1)
  end

  defp reason_class(reason) when is_atom(reason), do: reason
  defp reason_class({%{__struct__: module}, _trace}), do: module
  defp reason_class({reason, _detail}) when is_atom(reason), do: reason
  defp reason_class(_reason), do: :redacted

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
