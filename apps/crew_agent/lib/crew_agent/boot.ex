defmodule CrewAgent.Boot do
  @moduledoc "This host's boot id and OS version, for joins and `box.reboot` (§12.1)."

  @doc "The kernel's boot id, a lowercase UUID."
  def id do
    case :os.type() do
      {:unix, :linux} ->
        "/proc/sys/kernel/random/boot_id" |> File.read!() |> String.trim()

      {:unix, :darwin} ->
        {out, 0} = System.cmd("sysctl", ["-n", "kern.bootsessionuuid"])
        out |> String.trim() |> String.downcase()
    end
  rescue
    _ -> fallback_id()
  end

  # A stable id for this run when the host won't say (shouldn't happen).
  defp fallback_id do
    case :persistent_term.get({__MODULE__, :id}, nil) do
      nil ->
        id = CrewProtocol.uuid()
        :persistent_term.put({__MODULE__, :id}, id)
        id

      id ->
        id
    end
  end

  def os_version do
    case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("sw_vers", ["-productVersion"]) do
          {out, 0} -> String.trim(out)
          _ -> nil
        end

      _ ->
        with {:ok, body} <- File.read("/etc/os-release"),
             [_, v] <- Regex.run(~r/^VERSION_ID="?([^"\n]+)"?/m, body) do
          v
        else
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end
end
