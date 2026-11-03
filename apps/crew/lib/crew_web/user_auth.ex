defmodule CrewWeb.UserAuth do
  @moduledoc """
  Sessions for people signed in with GitHub: the plug that loads the
  current scope, sign-in and sign-out, and the LiveView mount hooks.
  """
  use CrewWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Crew.{Accounts, Scope}

  @github_fields [
    :access_token,
    :access_token_expires_at,
    :refresh_token,
    :refresh_token_expires_at,
    :github_login_expired,
    :updated_at
  ]

  @doc "Starts a session for `user`. The session is renewed to prevent fixation."
  def sign_in(conn, user) do
    token = Accounts.create_session(user, conn |> get_req_header("user-agent") |> List.first())
    return_to = get_session(conn, :return_to)

    conn
    |> renew_session()
    |> put_session(:session_token, token)
    |> put_session(:live_socket_id, "user_sessions:#{user.id}")
    |> redirect(to: safe_return(return_to))
  end

  # Only same-site paths, so a crafted return_to can't send the user elsewhere.
  defp safe_return("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]), do: ~p"/", else: path
  end

  defp safe_return(_), do: ~p"/"

  def sign_out(conn) do
    Accounts.delete_session(get_session(conn, :session_token))

    if id = get_session(conn, :live_socket_id) do
      CrewWeb.Endpoint.broadcast(id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/sign-in")
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @doc "Assigns `current_scope` from the session."
  def fetch_current_scope(conn, _opts) do
    user = conn |> get_session(:session_token) |> Accounts.get_user_by_session()
    assign(conn, :current_scope, Scope.for_user(user))
  end

  def require_user(conn, _opts) do
    if conn.assigns.current_scope.user do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: ~p"/sign-in")
      |> halt()
    end
  end

  def require_admin(conn, _opts) do
    if Scope.admin?(conn.assigns.current_scope) do
      conn
    else
      conn
      |> put_status(:not_found)
      |> put_view(CrewWeb.ErrorHTML)
      |> render("404.html")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn

  # -- LiveView ----------------------------------------------------------------

  def on_mount(:require_user, _params, session, socket) do
    socket = mount_scope(socket, session)

    if socket.assigns.current_scope.user do
      if Phoenix.LiveView.connected?(socket) do
        Phoenix.PubSub.subscribe(Crew.PubSub, "user:#{socket.assigns.current_scope.user.id}")
        Crew.Activity.subscribe()
      end

      {:cont,
       socket
       |> Phoenix.LiveView.attach_hook(:current_path, :handle_params, &put_current_path/3)
       |> Phoenix.LiveView.attach_hook(:user_events, :handle_info, &handle_user_event/2)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:require_admin, _params, _session, socket) do
    if Scope.admin?(socket.assigns.current_scope),
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
  end

  defp mount_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      session["session_token"] |> Accounts.get_user_by_session() |> Scope.for_user()
    end)
  end

  # The user was disabled or their role changed: reload the page so it
  # mounts again with their current access, instead of acting on the
  # scope this LiveView started with.
  defp handle_user_event(:access_changed, socket), do: reload(socket)

  # Their refresh token was rejected: pick up the cleared tokens so the
  # page shows the sign-in-again banner, without each view handling it.
  # Only the GitHub fields are taken, since forms built from the mounted
  # user diff their changes against the scope's.
  defp handle_user_event(:github_login_expired, socket) do
    %Scope{user: user} = socket.assigns.current_scope

    case Accounts.get_user(user.id) do
      nil ->
        reload(socket)

      fresh ->
        user = struct(user, Map.take(fresh, @github_fields))
        {:halt, Phoenix.Component.assign(socket, :current_scope, Scope.for_user(user))}
    end
  end

  # Activity anywhere in the fleet, shown as a notice on whatever page
  # this is, masked for members who can't read its repo (§18.3). Halted
  # either way: pages refresh from their own topics.
  defp handle_user_event({:activity, %Crew.Activity.Event{} = event}, socket) do
    event = Crew.Activity.for_scope(event, socket.assigns.current_scope)
    socket = Phoenix.LiveView.put_flash(socket, :info, event.message)

    case socket.view do
      CrewWeb.DashboardLive -> {:cont, socket}
      _ -> {:halt, socket}
    end
  end

  # A refresh took repos away (§18.3): a page about one of them goes back
  # to its list, and any other page reloads, so nothing it shows or is
  # subscribed to outlives the access.
  defp handle_user_event({:repo_access_changed, repo_ids}, socket) do
    case showing_repo(socket) do
      {repo_id, back} when is_binary(repo_id) ->
        if repo_id in repo_ids do
          {:halt,
           socket
           |> Phoenix.LiveView.put_flash(:error, "You no longer have access to that repo.")
           |> Phoenix.LiveView.push_navigate(to: back)}
        else
          {:halt, socket}
        end

      _ ->
        reload(socket)
    end
  end

  defp handle_user_event(_message, socket), do: {:cont, socket}

  defp showing_repo(%{assigns: %{attempt: %{repo_id: id}}}), do: {id, ~p"/runs"}
  defp showing_repo(%{assigns: %{repo: %{id: id}}}), do: {id, ~p"/repos"}
  defp showing_repo(_socket), do: nil

  defp reload(socket) do
    {:halt, Phoenix.LiveView.redirect(socket, to: socket.assigns[:current_path] || ~p"/")}
  end

  defp put_current_path(_params, uri, socket) do
    {:cont, Phoenix.Component.assign(socket, :current_path, URI.parse(uri).path)}
  end
end
