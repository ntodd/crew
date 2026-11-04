defmodule CrewAgent.Updater.RootStep do
  @moduledoc """
  A Linux update's root half (§10.8, §20.2). Everything root runs comes
  from `/srv/crew/root/<version>`, root's, and only root puts a release
  there: from the tarballs themselves, checked again against root's own
  copy of the release key, never from anything the agent unpacked.

  The agent stages, in `agent/update/` (its own directory):

      agent.tar.gz, cache.tar.gz    the downloads, as checked
      request                       one KEY=value per line:
          NONCE=<32 hex digits>     this request's, for root's answer
          VERSION=<version>
          TARGET=<linux-amd64|linux-arm64>
          AGENT_SHA256=<hex>  AGENT_SIG=<base64>
          CACHE_SHA256=<hex>  CACHE_SIG=<base64>

  `crew-root-install.path` (PathExists on `request`) starts
  `crew-root-install.service`, which runs `/etc/crew-box/root-install.sh`
  as root: it takes the request, checks both tarballs' SHA-256s and
  signatures, installs root's half (crew-vmctl, jailer, Firecracker, the
  ruleset and the units), moves `root/current`, reloads the units, and
  answers in `root/update.result` (root's, readable by all):

      ok <nonce> <version>
      error <nonce> <message>

  The agent waits for its nonce's answer (3 minutes at most).
  """

  alias CrewAgent.Config
  alias CrewAgent.Driver.Firecracker.Vmctl

  require Logger

  @timeout_ms 180_000

  @spec install(Config.t(), map(), keyword()) :: :ok | {:error, String.t()}
  def install(%Config{} = config, staged, opts \\ []) do
    stage = Path.join(Config.agent_dir(config), "update")
    result = Path.join([config.data_dir, "root", "update.result"])
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    with :ok <- check_staged(stage, staged),
         :ok <- write_request(stage, nonce, staged) do
      Logger.info("waiting for root to install #{staged.version}'s root half")

      wait(result, nonce, staged.version, config, opts)
    end
  end

  defp check_staged(stage, staged) do
    if staged.agent.path == Path.join(stage, "agent.tar.gz") and
         staged.cache.path == Path.join(stage, "cache.tar.gz"),
       do: :ok,
       else: {:error, "the tarballs aren't the staged ones in #{stage}"}
  end

  defp write_request(stage, nonce, staged) do
    body =
      [
        NONCE: nonce,
        VERSION: staged.version,
        TARGET: staged.target,
        AGENT_SHA256: staged.agent.sha256,
        AGENT_SIG: staged.agent.signature,
        CACHE_SHA256: staged.cache.sha256,
        CACHE_SIG: staged.cache.signature
      ]
      |> Enum.map_join(fn {k, v} -> "#{k}=#{v}\n" end)

    tmp = Path.join(stage, ".request.#{System.unique_integer([:positive])}")

    with :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, Path.join(stage, "request")) do
      :ok
    else
      {:error, reason} -> {:error, "can't write the request: #{:file.format_error(reason)}"}
    end
  end

  defp wait(result, nonce, version, config, opts) do
    poll = Keyword.get(opts, :poll_ms, 500)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @timeout_ms)
    do_wait(result, nonce, version, config, poll, deadline)
  end

  defp do_wait(result, nonce, version, config, poll, deadline) do
    case answer(result, nonce) do
      {:ok, ^version} ->
        current = Path.join([config.data_dir, "root", "current"])

        if File.read_link(current) == {:ok, version},
          do: :ok,
          else:
            {:error, "root said it installed #{version}, but root/current doesn't point at it"}

      {:ok, other} ->
        {:error, "root installed #{other}, not #{version}"}

      {:error, message} ->
        {:error, message}

      :none ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, "crew-root-install didn't answer (journalctl -u crew-root-install)"}
        else
          Process.sleep(poll)
          do_wait(result, nonce, version, config, poll, deadline)
        end
    end
  end

  defp answer(result, nonce) do
    case File.read(result) do
      {:ok, body} ->
        case String.split(String.trim_trailing(body, "\n"), " ", parts: 3) do
          ["ok", ^nonce, version] -> {:ok, version}
          ["error", ^nonce, message] -> {:error, String.slice(message, 0, 500)}
          _ -> :none
        end

      {:error, _} ->
        :none
    end
  end

  @doc """
  Restarts crew-cache onto the release `current` now points at, through
  crew-vmctl (§20.2). Its store survives; pulls fail for a few seconds,
  and Docker retries.
  """
  @spec restart_cache(Config.t()) :: :ok
  def restart_cache(%Config{} = config) do
    case Vmctl.request(config.vmctl_socket, %{"verb" => "restart-cache"}) do
      {:ok, _} ->
        :ok

      {:error, code, detail} ->
        Logger.warning("couldn't restart crew-cache onto the new release: #{code} #{detail}")
        :ok
    end
  end
end
