defmodule CrewCache.Allowlist do
  @moduledoc """
  The compiled hosts (`CrewProtocol.Hosts`, §15.3) and the cacheable
  allowlist: `<host>/<repository glob>` entries, where `*` matches any
  run of characters, `/` included (`mcr.microsoft.com/*` covers
  `dotnet/sdk`). Anything else in a glob is literal.

  Also the distribution spec's grammar for repositories, tags and
  digests: a request that doesn't fit isn't one the cache serves.
  """

  alias CrewProtocol.Hosts

  @repo ~r/\A[a-z0-9]+(?:(?:\.|_|__|-+)[a-z0-9]+)*(?:\/[a-z0-9]+(?:(?:\.|_|__|-+)[a-z0-9]+)*)*\z/
  @tag ~r/\A[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}\z/
  @sha256 ~r/\Asha256:([a-f0-9]{64})\z/

  @type compiled :: %{optional(String.t()) => [Regex.t()]}

  @doc "The compiled host whose Design A path prefix is `prefix`, or nil."
  def host_for_prefix(prefix), do: Enum.find(Hosts.all(), &(&1.prefix == prefix))

  @doc "Entries (already checked with `Hosts.allowlist_entry?/1`) as per-host patterns."
  @spec compile([String.t()]) :: compiled
  def compile(entries) do
    entries
    |> Enum.filter(&Hosts.allowlist_entry?/1)
    |> Enum.map(fn entry ->
      [host, glob] = String.split(entry, "/", parts: 2)
      {host, glob_regex(glob)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp glob_regex(glob) do
    body = glob |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)
    Regex.compile!("\\A" <> body <> "\\z")
  end

  @doc "Whether `repo` on `host` (a compiled host name) is cacheable."
  @spec allowed?(compiled, String.t(), String.t()) :: boolean
  def allowed?(compiled, host, repo) do
    compiled |> Map.get(host, []) |> Enum.any?(&Regex.match?(&1, repo))
  end

  @doc "Whether `name` is a repository name the distribution spec allows."
  def valid_repo?(name) when is_binary(name),
    do: byte_size(name) <= 255 and Regex.match?(@repo, name)

  def valid_repo?(_), do: false

  @doc "Whether `ref` is a tag."
  def valid_tag?(ref), do: Regex.match?(@tag, ref)

  @doc "The hex of a `sha256:` digest; other algorithms aren't served."
  def digest(ref) do
    case Regex.run(@sha256, ref) do
      [_, hex] -> {:ok, hex}
      nil -> :error
    end
  end
end
