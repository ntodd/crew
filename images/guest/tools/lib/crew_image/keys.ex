defmodule CrewImage.Keys do
  @moduledoc """
  The manifest signing key (docs/crew_spec.md §13.1, §20.1).

  A private key is the 32-byte ed25519 seed, base64: CrewProtocol.Auth's
  private key form. A public key is the raw 32 bytes, base64: what
  `CREW_RELEASE_PUBLIC_KEY` takes. Key files may carry `#` comments.

  Signing is `CrewProtocol.Auth.sign_manifest/2`: ed25519 over
  `"crew-manifest-v1\\n"` followed by the manifest's exact bytes. The
  domain prefix keeps a manifest signature from passing for a tarball's.

  `images/guest/keys/test-signing.key` is a **test key for development
  only**: it's committed, so anyone can sign with it. Loading it with
  `release: true` fails, as does verifying with it in release mode.
  """

  alias CrewProtocol.Auth

  @keys_dir Path.expand("../../../keys", __DIR__)
  @test_key Path.join(@keys_dir, "test-signing.key")
  @test_pub Path.join(@keys_dir, "test-signing.pub")
  @external_resource @test_pub

  {:ok, test_public} =
    @test_pub
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> List.first()
    |> Base.decode64()

  @test_public test_public

  def test_key_path, do: @test_key
  def test_public_key, do: @test_public
  def test_key?(public), do: public == @test_public

  @doc "Signs a manifest's exact bytes. Returns the signature, base64."
  def sign(bytes, private), do: Auth.sign_manifest(bytes, private)

  @doc "Verifies a base64 signature over a manifest's exact bytes."
  def verify(bytes, signature, public), do: Auth.verify_manifest(bytes, signature, public)

  def fingerprint(public), do: Auth.fingerprint(public)

  @doc """
  Loads the private key from `file:` or from the environment variable
  `env:` (`getenv:` replaces `System.get_env/1`, for tests). With
  `release: true` the test key is refused.
  """
  def load_private(opts) do
    with {:ok, text} <- source(opts),
         {:ok, private} <- parse_private(text) do
      if opts[:release] && test_key?(Auth.public_key(private)),
        do: {:error, :test_key_for_release},
        else: {:ok, private}
    end
  end

  @doc "Loads a public key from `file:`, or from `value:` (base64)."
  def load_public(file: path) do
    case File.read(path) do
      {:ok, text} -> parse_public(text)
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  def load_public(value: text), do: parse_public(text)

  def parse_private(text), do: parse(text)
  def parse_public(text), do: parse(text)

  defp parse(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    case lines do
      [] ->
        {:error, :no_key}

      [line] ->
        case Base.decode64(line) do
          {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
          _ -> {:error, :bad_key}
        end

      _ ->
        {:error, :bad_key}
    end
  end

  defp source(opts) do
    cond do
      path = opts[:file] ->
        case File.read(path) do
          {:ok, text} -> {:ok, text}
          {:error, reason} -> {:error, {:unreadable, path, reason}}
        end

      var = opts[:env] ->
        getenv = Keyword.get(opts, :getenv, &System.get_env/1)

        case getenv.(var) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, {:unset, var}}
        end
    end
  end
end
