defmodule CrewWeb.ObanResolver do
  @moduledoc "Oban Web for admins only (the router already requires an admin)."
  @behaviour Oban.Web.Resolver

  @impl true
  def resolve_user(%{assigns: %{current_scope: %{user: %{} = user}}}),
    do: Map.take(user, [:id, :login, :role])

  def resolve_user(_conn), do: nil

  @impl true
  def resolve_access(%{role: "admin"}), do: :all
  def resolve_access(_user), do: {:forbidden, "/"}
end
