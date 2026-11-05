defmodule CrewWeb.BoxController do
  @moduledoc """
  The reprovision Ignition, from the box page (§12.2): a download, so it's
  a plain request rather than the LiveView's. It holds no secrets.
  """
  use CrewWeb, :controller

  alias Crew.Boxes

  def reprovision(conn, %{"id" => id} = params) do
    with true <- CrewProtocol.uuid?(id),
         %Boxes.Box{} = box <- Boxes.get(id),
         {:ok, config} <- Boxes.reprovision_ignition(conn.assigns.current_scope, box, params) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="crew-#{box.name}-#{params["arch"]}-reprovision.ign")
      )
      |> json(config)
    else
      {:error, reason} when reason in [:bad_arch, :bad_data_disk, :bad_ssh_key, :not_flatcar] ->
        conn |> put_status(:bad_request) |> json(%{error: error(reason)})

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "no such box"})
    end
  end

  @doc """
  A `mac-vz` box's cache VM's reprovision Ignition (§12.3): no token,
  and the newest release, which a new OS disk moves crew_cache to. Used
  with `crew-box reimage <file> cachevm` on the Mac.
  """
  def cachevm_reprovision(conn, %{"id" => id} = params) do
    with true <- CrewProtocol.uuid?(id),
         %Boxes.Box{} = box <- Boxes.get(id),
         {:ok, config} <-
           Boxes.cachevm_reprovision_ignition(conn.assigns.current_scope, box, params) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="crew-#{box.name}-cachevm-reprovision.ign")
      )
      |> json(config)
    else
      {:error, reason} when reason in [:bad_ssh_key, :not_mac_vz] ->
        conn |> put_status(:bad_request) |> json(%{error: error(reason)})

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "no such box"})
    end
  end

  defp error(:not_mac_vz), do: "only a mac-vz box has a cache VM"
  defp error(:bad_arch), do: "arch must be amd64 or arm64"
  defp error(:bad_data_disk), do: "the data disk must be a device like /dev/sdb"
  defp error(:bad_ssh_key), do: "that isn't an SSH public key"
  defp error(:not_flatcar), do: "this box doesn't run Flatcar"
end
