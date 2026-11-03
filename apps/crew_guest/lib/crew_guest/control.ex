defmodule CrewGuest.Control do
  @moduledoc """
  Keeps one `GET /v1/control` long poll open (§13.4, §13.5 step 11). The
  agent holds it for up to 30 s and answers 204, or `{"stop": true}` once a
  stop is requested. The stop itself is reported by `CrewGuest.API`, as it
  is for every other response; this process just polls again, backing off
  when a poll fails, and exits once it has seen the stop.
  """

  use Task, restart: :transient

  alias CrewGuest.{API, Backoff}

  def start_link(opts), do: Task.start_link(__MODULE__, :run, [opts])

  @doc false
  def run(opts) do
    client = Keyword.fetch!(opts, :client)
    backoff = {Keyword.get(opts, :backoff_min_ms, 500), Keyword.get(opts, :backoff_max_ms, 5_000)}
    poll(client, backoff, 0)
  end

  defp poll(client, {min, max} = backoff, failures) do
    case API.get_control(client) do
      {:ok, :stop} ->
        :ok

      {:ok, :continue} ->
        poll(client, backoff, 0)

      {:error, _reason} ->
        Process.sleep(Backoff.delay(failures + 1, min, max))
        poll(client, backoff, failures + 1)
    end
  end
end
