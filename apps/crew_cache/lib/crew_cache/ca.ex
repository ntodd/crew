defmodule CrewCache.CA do
  @moduledoc """
  The per-box CA (§15.4), kept in `<cache dir>/ca/` (0700):

  | File | |
  |---|---|
  | `root.pem` | The root certificate, the guests' trust anchor (`GET /ca.pem`) |
  | `intermediate.pem`, `intermediate.key` | The intermediate and its key (0600) |
  | `leaf.pem`, `leaf.key` | The serving leaf followed by the intermediate, and its key (0600) |

  The root key only ever exists inside `CrewCache.CA.Certs.chain/1`.

  The chain is made on first start, and again when the listen IP changes
  (its name constraints name the IP), when the intermediate has less
  than 30 days left, and on `rotate/0`. The leaf is replaced when it's a
  day old: the registry's listener reads `leaf.pem` through OTP's PEM
  cache, which is cleared on each change, so new handshakes get the new
  leaf without a restart.
  """
  use GenServer

  require Logger

  alias CrewCache.CA.Certs

  @check_ms 60 * 60_000
  @leaf_max_age_s 24 * 3600

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The root certificate, PEM."
  def root_pem(server \\ __MODULE__), do: GenServer.call(server, :root_pem)

  @doc "Regenerate the whole chain. VMs started afterwards get the new root."
  def rotate(server \\ __MODULE__), do: GenServer.call(server, :rotate, 30_000)

  @doc "The files a TLS listener serves (`certfile` holds the leaf and the intermediate)."
  def tls_files(server \\ __MODULE__), do: GenServer.call(server, :tls_files)

  # -- files ------------------------------------------------------------------

  defp ca_dir(dir), do: Path.join(dir, "ca")
  defp file(dir, name), do: Path.join(ca_dir(dir), name)

  @doc false
  def load_chain(dir) do
    with {:ok, root} <- File.read(file(dir, "root.pem")),
         {:ok, inter} <- File.read(file(dir, "intermediate.pem")),
         {:ok, key} <- File.read(file(dir, "intermediate.key")) do
      %{
        root: Certs.from_pem(root),
        intermediate: Certs.from_pem(inter),
        intermediate_key: Certs.key_from_pem(key)
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp write_chain(dir, chain) do
    write(file(dir, "intermediate.key"), Certs.key_pem(chain.intermediate_key), 0o600)
    write(file(dir, "intermediate.pem"), Certs.pem(chain.intermediate), 0o644)
    write(file(dir, "root.pem"), Certs.pem(chain.root), 0o644)
  end

  @doc false
  def write_leaf(dir, chain, leaf, key) do
    write(file(dir, "leaf.key"), Certs.key_pem(key), 0o600)
    write(file(dir, "leaf.pem"), Certs.pem(leaf) <> Certs.pem(chain.intermediate), 0o644)
  end

  # Written whole and renamed into place; keys are 0600 before they have
  # anything in them.
  defp write(path, data, mode) do
    tmp = path <> ".tmp"
    File.rm(tmp)
    {:ok, io} = File.open(tmp, [:write, :exclusive, :binary])
    :ok = File.chmod(tmp, mode)
    :ok = IO.binwrite(io, data)
    :ok = File.close(io)
    :ok = File.rename(tmp, path)
  end

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.fetch!(opts, :dir)
    ip = Keyword.fetch!(opts, :ip)
    File.mkdir_p!(ca_dir(dir))
    File.chmod!(ca_dir(dir), 0o700)

    state = %{dir: dir, ip: ip, chain: nil}
    state = %{state | chain: ensure_chain(state)}
    ensure_leaf(state, false)
    Process.send_after(self(), :check, @check_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:root_pem, _from, state), do: {:reply, Certs.pem(state.chain.root), state}

  def handle_call(:tls_files, _from, %{dir: dir} = state) do
    {:reply, %{certfile: file(dir, "leaf.pem"), keyfile: file(dir, "leaf.key")}, state}
  end

  def handle_call(:rotate, _from, state) do
    state = %{state | chain: new_chain(state)}
    ensure_leaf(state, true)
    Logger.info("rotated the cache CA")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    Process.send_after(self(), :check, @check_ms)
    state = %{state | chain: ensure_chain(state)}
    ensure_leaf(state, false)
    {:noreply, state}
  end

  defp ensure_chain(%{dir: dir, ip: ip} = state) do
    chain = load_chain(dir)
    if chain && usable?(chain, ip), do: chain, else: new_chain(state)
  end

  defp new_chain(%{dir: dir, ip: ip}) do
    chain = Certs.chain(ip)
    write_chain(dir, chain)
    chain
  end

  defp usable?(chain, {a, b, c, d}) do
    cert = Certs.decode(chain.intermediate)
    {_, not_after} = Certs.validity(cert)

    match?(
      {true, %{permitted: [{:iPAddress, <<^a, ^b, ^c, ^d, 255, 255, 255, 255>>}]}},
      Certs.ext(cert, :name_constraints)
    ) and DateTime.diff(not_after, DateTime.utc_now(), :day) > 30
  end

  defp ensure_leaf(%{dir: dir, ip: ip, chain: chain}, force?) do
    if force? or not fresh_leaf?(dir, chain) do
      {leaf, key} = Certs.leaf(chain, ip)
      write_leaf(dir, chain, leaf, key)
      :ssl.clear_pem_cache()
    end
  end

  defp fresh_leaf?(dir, chain) do
    with {:ok, pem} <- File.read(file(dir, "leaf.pem")),
         true <- File.exists?(file(dir, "leaf.key")),
         [{_, leaf, _} | _] <- :public_key.pem_decode(pem),
         true <- :public_key.pkix_is_issuer(leaf, chain.intermediate) do
      {not_before, _} = leaf |> Certs.decode() |> Certs.validity()
      # Leaves start an hour back (Certs.leaf/3).
      DateTime.diff(DateTime.utc_now(), not_before, :second) < @leaf_max_age_s + 3600
    else
      _ -> false
    end
  rescue
    _ -> false
  end
end
