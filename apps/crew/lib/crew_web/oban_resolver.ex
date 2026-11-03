defmodule CrewWeb.ObanResolver do
  @moduledoc "Oban Web for admins only (the router already requires an admin)."
  @behaviour Oban.Web.Resolver

  @impl true
  def resolve_user(conn), do: conn.assigns[:current_scope] && conn.assigns.current_scope.user

  @impl true
  def resolve_access(%{role: "admin"}), do: :all
  def resolve_access(_user), do: {:forbidden, "/"}
end
