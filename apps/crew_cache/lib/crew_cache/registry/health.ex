defmodule CrewCache.Registry.Health do
  @moduledoc "Plain HTTP on :80 (§15.2): `/healthz` and nothing else."
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{path_info: ["healthz"], method: method} = conn, _) when method in ~w(GET HEAD),
    do: send_resp(conn, 200, "ok")

  def call(conn, _), do: send_resp(conn, 404, "")
end
