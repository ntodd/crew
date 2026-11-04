defmodule CrewCache.Parent do
  @moduledoc """
  The box side of the parent cache (§15.7): by-digest manifest and blob
  fetches for allowlisted repositories ask the parent first, with the
  box's bearer token, over TLS that trusts only the parent's pinned CA.
  Tags never come here (`CrewCache.Registry` resolves them upstream).

  - **Falling back:** a parent that can't be reached, answers anything
    but 2xx, or takes longer than `parent_first_byte_ms` (5 s) to its
    first byte means the upstream, within the same fetch: no client has
    seen a byte yet.
  - **Verifying:** every digest from the parent is checked
    (`CrewCache.Fetcher`). A parent that fails after it started sending,
    or sends the wrong bytes, cuts that fetch short, and the digest
    skips the parent for 10 minutes, so the client's retry goes upstream.
  - **The one address-policy exception:** the parent lives on the
    tailnet (`100.64.0.0/10`, in blocked4), so its connections don't go
    through `CrewCache.Dial`; its name resolves the system's way
    (MagicDNS). It's configured by the control plane, pinned by CA and
    token, and everything it returns is verified.

  This process owns the parent's own Finch pool and restarts it when the
  parent changes.
  """
  use GenServer

  require Logger

  alias CrewCache.{Config, Settings, Upstream}
  alias CrewCache.Upstream.Memo

  @finch CrewCache.ParentFinch
  @skip_ms 10 * 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Pick up a changed parent."
  def reconfigure do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :reconfigure), else: :ok
  end

  @doc "Stop asking the parent for `digest` for a while."
  def skip(digest), do: Memo.flag({:parent_skip, digest}, @skip_ms)

  @doc """
  Fetch `spec` from the parent into `sink`. `:skip` when there's no
  parent (or it's skipped for this digest), `:fallback` when it failed
  before sending anything, else what `Upstream.send_one/4` returned.
  """
  def fetch(spec, headers, sink) do
    parent = Settings.current().parent

    if parent == nil or Memo.flagged?({:parent_skip, spec.digest}),
      do: :skip,
      else: ask(parent, spec, headers, sink)
  end

  defp ask(parent, spec, headers, sink) do
    kind = if spec.kind == :manifest, do: "manifests", else: "blobs"
    url = "#{parent.url}/v2/#{spec.host.prefix}/#{spec.repo}/#{kind}/#{spec.digest}"

    "GET"
    |> Upstream.send_one(url, [{"authorization", "Bearer " <> parent.token} | headers],
      finch: @finch,
      sink: sink,
      receive_timeout: Config.get().parent_first_byte_ms
    )
    |> classify(spec)
  end

  defp classify({:ok, %{status: status, sink: %{started: true}}} = ok, _spec)
       when status in 200..299,
       do: ok

  defp classify({:ok, %{status: status}}, spec) do
    Logger.info("parent answered #{status} for #{spec.digest}; asking the upstream")
    :fallback
  end

  defp classify({:error, reason, %{started: false}}, spec) do
    Logger.info("parent failed for #{spec.digest} (#{describe(reason)}); asking the upstream")
    :fallback
  end

  defp classify({:error, reason, _sink} = error, spec) do
    Logger.warning("parent failed mid-fetch for #{spec.digest}: #{describe(reason)}")
    skip(spec.digest)
    error
  end

  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(other), do: inspect(other)

  # -- the pool -----------------------------------------------------------------

  @impl true
  def init(_), do: {:ok, start_pool(%{pool: nil})}

  @impl true
  def handle_call(:reconfigure, _from, state) do
    if state.pool, do: Supervisor.stop(state.pool, :normal)
    {:reply, :ok, start_pool(%{state | pool: nil})}
  end

  defp start_pool(state) do
    case Settings.current().parent do
      nil ->
        state

      %{cacerts: cacerts} ->
        {:ok, pid} =
          Finch.start_link(
            name: @finch,
            pools: %{
              default: [size: 8, conn_opts: [transport_opts: [cacerts: cacerts, timeout: 5_000]]]
            }
          )

        %{state | pool: pid}
    end
  end
end
