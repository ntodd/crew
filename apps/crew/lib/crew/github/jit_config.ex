defmodule Crew.GitHub.JitConfig do
  @moduledoc """
  GitHub's JIT config (§6.3): base64 of a JSON object whose values are the
  runner's settings files, each base64 again.

  The runner must never update itself in a VM, and the guest refuses a
  config whose `.runner` doesn't say so (§13.5 step 7). GitHub's
  `generate-jitconfig` has no switch for it and leaves `DisableUpdate`
  out (spike S9), so the control plane sets it: it's the same setting
  `config.sh --disableupdate` writes, and the runner sends it to GitHub
  with every poll.
  """

  @doc """
  The config with `"DisableUpdate": true` in its `.runner`. A config it
  can't read goes through unchanged; the guest refuses it.
  """
  @spec disable_update(String.t()) :: String.t()
  def disable_update(jit) do
    with {:ok, files} when is_map(files) <- decode(jit),
         {:ok, runner} when is_map(runner) <- decode(files[".runner"]) do
      runner = runner |> Map.put("DisableUpdate", true) |> encode()
      files |> Map.put(".runner", runner) |> encode()
    else
      _ -> jit
    end
  end

  defp decode(value) when is_binary(value) do
    with {:ok, json} <- Base.decode64(value, padding: false), do: Jason.decode(json)
  end

  defp decode(_value), do: :error

  defp encode(term), do: term |> Jason.encode!() |> Base.encode64()
end
