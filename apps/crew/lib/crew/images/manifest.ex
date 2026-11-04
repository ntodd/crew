defmodule Crew.Images.Manifest do
  @moduledoc """
  A guest image's manifest (§13.1), as CI writes it: the version and
  arch, the kernel's and compressed root filesystem's SHA-256 and sizes,
  the decompressed root filesystem's, and what the image carries. Only
  read once its signature is checked.
  """

  @sha ~r/\A[0-9a-f]{64}\z/
  @version ~r/\A\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?\z/

  @doc "The fields `Crew.Images.Image` keeps, or `{:error, reason}`."
  def parse(bytes) when is_binary(bytes) do
    with {:ok, %{} = m} <- Jason.decode(bytes),
         :ok <- check(m) do
      {:ok,
       %{
         version: m["version"],
         arch: m["arch"],
         kernel_sha256: m["kernel_sha256"],
         kernel_size: m["kernel_size"],
         rootfs_sha256: m["rootfs_sha256"],
         rootfs_size: m["rootfs_size"],
         rootfs_ext4_sha256: m["rootfs_ext4_sha256"],
         rootfs_ext4_size: m["rootfs_ext4_size"],
         runner_version: m["runner_version"],
         docker_version: string(m["docker_version"]),
         kernel_version: string(m["kernel_version"]),
         packages_lock_sha256: string(m["packages_lock_sha256"])
       }}
    else
      {:ok, _} -> {:error, "not a JSON object"}
      {:error, %Jason.DecodeError{}} -> {:error, "not JSON"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check(m) do
    cond do
      not (is_binary(m["version"]) and m["version"] =~ @version) ->
        {:error, "bad version"}

      m["arch"] not in ["arm64", "x64"] ->
        {:error, "bad arch"}

      not Enum.all?(~w(kernel_sha256 rootfs_sha256 rootfs_ext4_sha256), &sha?(m[&1])) ->
        {:error, "bad SHA-256"}

      not Enum.all?(~w(kernel_size rootfs_size rootfs_ext4_size), &size?(m[&1])) ->
        {:error, "bad size"}

      not (is_binary(m["runner_version"]) and m["runner_version"] != "") ->
        {:error, "no runner version"}

      true ->
        :ok
    end
  end

  defp sha?(v), do: is_binary(v) and v =~ @sha
  defp size?(v), do: is_integer(v) and v > 0
  defp string(v) when is_binary(v), do: v
  defp string(_), do: nil
end
