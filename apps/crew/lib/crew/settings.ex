defmodule Crew.Settings do
  @moduledoc """
  Deployment settings kept in the database, encrypted: the GitHub App's
  credentials (when created through the manifest flow), the public host
  and the deployment id, and similar. Environment variables take
  precedence where both exist.
  """
  import Ecto.Query

  require Logger

  alias Crew.Repo
  alias Crew.Settings.Setting

  @check_key "encryption_key_check"

  def get(key, default \\ nil) do
    case Repo.get(Setting, key) do
      %Setting{value: %{"v" => value}} -> value
      _ -> default
    end
  end

  def put(key, value) do
    %Setting{key: key}
    |> Ecto.Changeset.change(value: %{"v" => value})
    |> Repo.insert!(on_conflict: {:replace, [:value, :updated_at]}, conflict_target: :key)

    :ok
  end

  # -- the deployment (§21.1) --------------------------------------------------

  @host ~r/\A(?=.{1,253}\z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/

  @doc "The tailnet host name people and GitHub reach the control plane by, e.g. crew.tail1234.ts.net."
  def public_host, do: get("public_host")

  @doc "Sets the public host, lowercased. It must be a plain DNS name, without scheme or port."
  def put_public_host(host) when is_binary(host) do
    host = host |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    if Regex.match?(@host, host) do
      put("public_host", host)
      {:ok, host}
    else
      {:error, "must be a host name like crew.tail1234.ts.net, without https:// or a port"}
    end
  end

  @doc "This deployment's id (§3), generated once, at setup."
  def deployment_id do
    case get("deployment_id") do
      id when is_binary(id) -> id
      nil -> nil
    end
  end

  @doc "The deployment id, generating it the first time."
  def ensure_deployment_id do
    case deployment_id() do
      nil ->
        id = Application.get_env(:crew, :deployment_id) || CrewProtocol.Names.new_deployment_id()
        put("deployment_id", id)
        id

      id ->
        id
    end
  end

  @doc """
  Checks CREW_ENCRYPTION_KEY against what's stored, and stops the boot
  if it can't read it. A boot step, before anything decrypts: otherwise
  Crew.Setup reads the GitHub App and crashes with a stack trace that
  doesn't mention the key, on every restart.
  """
  def start_checking_encryption_key do
    case check_encryption_key() do
      :ok ->
        :ignore

      {:error, message} ->
        Logger.error(message)
        {:error, :wrong_encryption_key}
    end
  end

  @doc """
  `:ok` if the vault's keys decrypt what's stored.

  A setting records the IDs of the keys the data may be under. While all
  of them are configured, the settings are all that's checked, and the
  current key is added, since it's what's written with from now on. A
  recorded key that isn't configured (a retired key dropped before
  re-encrypting finished, or going back to the old key after the new
  one wrote something), or nothing recorded yet, means checking every
  encrypted value, then recording the keys that are still needed.
  """
  def check_encryption_key do
    rows = Repo.all(from s in "settings", select: {s.key, s.value})

    case for {key, value} <- rows,
             Crew.Vault.which_key(value) == :none,
             do: "the #{key} setting" do
      [] -> check_recorded_keys(Crew.Vault.key_ids())
      unreadable -> {:error, wrong_key_message(unreadable)}
    end
  end

  defp check_recorded_keys([current | _] = configured) do
    recorded =
      case get(@check_key) do
        %{"keys" => ids} when is_list(ids) -> ids
        _ -> nil
      end

    if recorded && recorded -- configured == [] do
      record_keys(recorded, Enum.uniq(recorded ++ [current]))
    else
      keys = value_keys()

      case for({name, :none} <- keys, uniq: true, do: name) do
        [] ->
          needed = if Enum.all?(keys, &match?({_, :current}, &1)), do: [current], else: configured
          record_keys(recorded, needed)

        unreadable ->
          {:error, wrong_key_message(unreadable)}
      end
    end
  end

  defp record_keys(ids, ids), do: :ok
  defp record_keys(_, ids), do: put(@check_key, %{"keys" => ids})

  # {"users.access_token", :current | :retired | :none} for every
  # encrypted value.
  defp value_keys do
    for {schema, fields} <- Crew.Vault.encrypted_schemas(),
        source = schema.__schema__(:source),
        field <- fields,
        value <-
          Repo.all(
            from s in source, where: not is_nil(field(s, ^field)), select: field(s, ^field)
          ),
        do: {"#{source}.#{field}", Crew.Vault.which_key(value)}
  end

  defp wrong_key_message(unreadable) do
    """
    CREW_ENCRYPTION_KEY isn't the key this database was encrypted with: \
    it can't decrypt #{Enum.join(unreadable, ", ")}. \
    Put the original key back. If you're changing it, the old one goes in \
    CREW_ENCRYPTION_KEYS_RETIRED until Crew.Release.reencrypt() has run \
    (docs/setup/upgrading.md).\
    """
  end
end
