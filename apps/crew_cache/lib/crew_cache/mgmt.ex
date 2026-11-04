defmodule CrewCache.Mgmt do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "")
end
