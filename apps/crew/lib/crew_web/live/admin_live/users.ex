defmodule CrewWeb.AdminLive.Users do
  @moduledoc """
  People who've signed in: their roles, and disabling them.
  """
  use CrewWeb, :live_view

  alias Crew.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "People") |> assign(:users, Accounts.list_users())}
  end

  @impl true
  def handle_event("role", %{"id" => id, "role" => role}, socket) do
    respond(socket, Accounts.set_role(socket.assigns.current_scope, Accounts.get_user!(id), role))
  end

  def handle_event("disable", %{"id" => id, "disabled" => disabled}, socket) do
    respond(
      socket,
      Accounts.set_disabled(
        socket.assigns.current_scope,
        Accounts.get_user!(id),
        disabled == "true"
      )
    )
  end

  defp respond(socket, {:ok, _}),
    do: {:noreply, socket |> assign(:users, Accounts.list_users()) |> put_flash(:info, "Saved.")}

  defp respond(socket, {:error, :self}),
    do: {:noreply, put_flash(socket, :error, "You can't change your own access.")}

  defp respond(socket, {:error, _}),
    do: {:noreply, put_flash(socket, :error, "Couldn't save that.")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      width="narrow"
    >
      <:breadcrumb>People</:breadcrumb>
      <.header>
        People
        <:subtitle>
          Everyone who has signed in. Who may sign in is set by CREW_ADMINS, CREW_ALLOWED_USERS and CREW_ALLOWED_ORG.
        </:subtitle>
      </.header>

      <section class="rounded-xl border border-line bg-raised shadow-xs">
        <ul class="divide-y divide-line">
          <li :for={user <- @users} id={"user-#{user.id}"} class="flex items-center gap-3 px-5 py-3">
            <.avatar user={user} class="size-8 text-xs" />
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-medium text-ink">{user.login}</p>
              <p class="truncate text-xs text-ink-3">
                {user.name}<span :if={user.github_login_expired}> · GitHub login expired</span><span :if={
                  user.disabled_at
                }> · disabled</span>
              </p>
            </div>
            <.badge :if={user.role == "admin"} color="brand" size="sm">Admin</.badge>
            <%= if user.id != @current_scope.user.id do %>
              <.button
                size="sm"
                variant="ghost"
                phx-click="role"
                phx-value-id={user.id}
                phx-value-role={if user.role == "admin", do: "member", else: "admin"}
              >
                {if user.role == "admin", do: "Make member", else: "Make admin"}
              </.button>
              <.button
                size="sm"
                variant={if user.disabled_at, do: "secondary", else: "danger_outline"}
                phx-click="disable"
                phx-value-id={user.id}
                phx-value-disabled={to_string(is_nil(user.disabled_at))}
              >
                {if user.disabled_at, do: "Enable", else: "Disable"}
              </.button>
            <% end %>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
