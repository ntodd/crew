defmodule CrewWeb.SizingActions do
  @moduledoc """
  Dismissing and restoring right-sizing hints (§7.5), the same on the job,
  repo and right-sizing pages. A page passes each of `events/0` here with
  a function that reads its hints again.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Crew.Sizing

  @events ~w(dismissing dismiss_hint restore_hint toggle_dismissed)

  @doc "The events `handle/4` takes."
  def events, do: @events

  @doc "What a page starts with: no dismiss form open, the dismissed list shut."
  def mount(socket), do: socket |> assign(:dismissing, nil) |> assign(:show_dismissed, false)

  def handle("dismissing", params, socket, _reload),
    do: {:noreply, assign(socket, :dismissing, params["job"])}

  def handle("toggle_dismissed", _params, socket, _reload),
    do: {:noreply, assign(socket, :show_dismissed, !socket.assigns.show_dismissed)}

  def handle("dismiss_hint", %{"job_id" => id} = params, socket, reload) do
    socket.assigns.current_scope
    |> Sizing.dismiss(id, params)
    |> done(socket, reload, "Hint dismissed.")
  end

  def handle("restore_hint", %{"id" => id}, socket, reload) do
    socket.assigns.current_scope
    |> Sizing.restore(id)
    |> done(socket, reload, "Hint restored.")
  end

  def handle(_event, _params, socket, _reload), do: {:noreply, socket}

  defp done(result, socket, reload, ok) do
    socket = socket |> assign(:dismissing, nil) |> reload.()

    case result do
      {:ok, _} -> {:noreply, put_flash(socket, :info, ok)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, message(reason))}
    end
  end

  defp message(:unauthorized), do: "Only admins can dismiss or restore hints."

  defp message(:changed),
    do: "That hint changed while the form was open. Here's what it says now."

  defp message(:not_found), do: "That hint isn't there any more."
  defp message(%Ecto.Changeset{}), do: "Keep the reason under 500 characters."
end
