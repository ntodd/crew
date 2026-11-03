defmodule Crew.Scope do
  @moduledoc """
  Who is acting. Every context function that reads or changes data on a
  user's behalf takes a scope and filters or authorizes by it.
  """
  alias Crew.Accounts.User

  defstruct user: nil

  @type t :: %__MODULE__{user: User.t() | nil}

  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: %__MODULE__{}

  def admin?(%__MODULE__{user: %User{role: "admin"}}), do: true
  def admin?(_), do: false

  def user_id(%__MODULE__{user: %User{id: id}}), do: id
  def user_id(_), do: nil
end
