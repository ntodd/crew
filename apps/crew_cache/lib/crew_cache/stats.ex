defmodule CrewCache.Stats do
  @moduledoc """
  Counters since the cache started (§15.8 `GET /stats`): per host, hits,
  misses, bytes served and digest mismatches; evictions; and per
  repository, hits and bytes served, for the Caches page's top images.

  A hit is an object served from the store, a miss one fetched from the
  upstream. A manifest by tag counts as its manifest by digest.

  At most #{1000} repositories are tracked; past that, new ones aren't.
  """
  use GenServer

  @table __MODULE__
  @max_repos 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def hit(host, repo), do: count(host, repo, 2)
  def miss(host, repo), do: count(host, repo, 3)

  def served(_host, _repo, 0), do: :ok

  def served(host, repo, bytes) do
    bump({:host, host}, [{4, bytes}], {{:host, host}, 0, 0, 0, 0})
    repo_bump(host, repo, [{3, bytes}])
  end

  def mismatch(host) do
    bump({:host, host}, [{5, 1}], {{:host, host}, 0, 0, 0, 0})
    bump(:digest_mismatches, [{2, 1}], {:digest_mismatches, 0})
  end

  def evicted(0), do: :ok
  def evicted(n), do: bump(:evictions, [{2, n}], {:evictions, 0})

  defp count(host, repo, pos) do
    bump({:host, host}, [{pos, 1}], {{:host, host}, 0, 0, 0, 0})
    if pos == 2, do: repo_bump(host, repo, [{2, 1}]), else: :ok
  end

  defp repo_bump(host, repo, ops) do
    key = {:repo, host, repo}

    if :ets.member(@table, key) or :ets.info(@table, :size) < @max_repos + 16 do
      bump(key, ops, {key, 0, 0})
    else
      :ok
    end
  end

  defp bump(key, ops, default) do
    :ets.update_counter(@table, key, ops, default)
    :ok
  rescue
    # Stats aren't running (a test of one part): nothing to count.
    ArgumentError -> :ok
  end

  @doc "The counters, and the top 10 repositories by bytes served."
  def snapshot do
    rows = :ets.tab2list(@table)

    hosts =
      for {{:host, host}, hits, misses, bytes, mismatches} <- rows, into: %{} do
        {host, %{hits: hits, misses: misses, bytes_served: bytes, mismatches: mismatches}}
      end

    top =
      for(
        {{:repo, host, repo}, hits, bytes} <- rows,
        bytes > 0 or hits > 0,
        do: %{host: host, repo: repo, hits: hits, bytes_served: bytes}
      )
      |> Enum.sort_by(&{-&1.bytes_served, -&1.hits, &1.host, &1.repo})
      |> Enum.take(10)

    %{
      hosts: hosts,
      evictions: value(rows, :evictions),
      digest_mismatches: value(rows, :digest_mismatches),
      top: top
    }
  end

  defp value(rows, key) do
    Enum.find_value(rows, 0, fn
      {^key, n} -> n
      _ -> nil
    end)
  end

  @doc """
  A random id for this run of the counters, made when they start and
  never saved: when it changes, they started again from zero.
  """
  def instance, do: :persistent_term.get({__MODULE__, :instance}, nil)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])

    :persistent_term.put(
      {__MODULE__, :instance},
      Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    )

    {:ok, nil}
  end
end
