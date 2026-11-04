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

  @doc "The same, from the cache directory (they exist once the CA has started)."
  def files(dir), do: %{certfile: file(dir, "leaf.pem"), keyfile: file(dir, "leaf.key")}

  @doc "Where the root certificate is kept."
  def root_file(dir), do: file(dir, "root.pem")

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
    {chain, new?} = ensure_chain(state)
    state = %{state | chain: chain}
    ensure_leaf(state, new?)
    Process.send_after(self(), :check, @check_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:root_pem, _from, state), do: {:reply, Certs.pem(state.chain.root), state}

  def handle_call(:tls_files, _from, %{dir: dir} = state), do: {:reply, files(dir), state}

  def handle_call(:rotate, _from, state) do
    state = %{state | chain: new_chain(state)}
    ensure_leaf(state, true)
    Logger.info("rotated the cache CA")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    Process.send_after(self(), :check, @check_ms)
    {chain, new?} = ensure_chain(state)
    state = %{state | chain: chain}
    ensure_leaf(state, new?)
    {:noreply, state}
  end

  # The chain, and whether it's new: a new chain always gets a new leaf.
  defp ensure_chain(%{dir: dir, ip: ip} = state) do
    chain = load_chain(dir)
    if chain && usable?(chain, ip), do: {chain, false}, else: {new_chain(state), true}
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
    if force? or not fresh_leaf?(dir, chain, ip) do
      {leaf, key} = Certs.leaf(chain, ip)
      write_leaf(dir, chain, leaf, key)
      :ssl.clear_pem_cache()
    end
  end

  # The leaf on disk is kept only if the current intermediate signed it
  # (not just a certificate with its name: every intermediate has the
  # same one), it's for the listen IP, its key is the one beside it, and
  # it's under a day old.
  defp fresh_leaf?(dir, chain, {a, b, c, d}) do
    with {:ok, pem} <- File.read(file(dir, "leaf.pem")),
         {:ok, key_pem} <- File.read(file(dir, "leaf.key")),
         [{_, leaf, _} | _] <- :public_key.pem_decode(pem),
         cert = Certs.decode(leaf),
         true <-
           :public_key.pkix_verify(
             leaf,
             chain.intermediate |> Certs.decode() |> Certs.public_key()
           ),
         {_, [{:iPAddress, <<^a, ^b, ^c, ^d>>}]} <- Certs.ext(cert, :subject_alt_name),
         true <- Certs.public_of(Certs.key_from_pem(key_pem)) == Certs.public_key(cert) do
      {not_before, _} = Certs.validity(cert)
      # Leaves start an hour back (Certs.leaf/3).
      DateTime.diff(DateTime.utc_now(), not_before, :second) < @leaf_max_age_s + 3600
    else
      _ -> false
    end
  rescue
    _ -> false
  end
end
