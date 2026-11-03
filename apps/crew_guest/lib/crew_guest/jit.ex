defmodule CrewGuest.JIT do
  @moduledoc """
  The JIT config check (§13.5 step 7, spike S9).

  GitHub's `encoded_jit_config` is base64 of a JSON object whose values are
  the runner's settings files, each base64 again. The `.runner` file must
  carry `"DisableUpdate": true`: a runner must never update itself in a
  VM, so crew-guest refuses to start one that would.
  """

  @spec check(term()) :: :ok | {:error, :update_not_disabled | :bad_jit_config}
  def check(encoded) do
    with {:ok, files} <- decode_json(encoded),
         true <- is_map(files) || :bad,
         {:ok, runner} <- decode_json(files[".runner"]),
         true <- is_map(runner) || :bad do
      if runner["DisableUpdate"] === true, do: :ok, else: {:error, :update_not_disabled}
    else
      _ -> {:error, :bad_jit_config}
    end
  end

  defp decode_json(value) when is_binary(value) do
    with {:ok, json} <- decode64(String.trim(value)) do
      Jason.decode(json)
    end
  end

  defp decode_json(_value), do: :error

  defp decode64(value) do
    with :error <- Base.decode64(value, padding: false) do
      Base.url_decode64(value, padding: false)
    end
  end
end
