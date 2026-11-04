defmodule CrewCache.DNS do
  @moduledoc false

  def child_spec(config),
    do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> config end, [name: __MODULE__]]}}

  def port, do: 0
end
