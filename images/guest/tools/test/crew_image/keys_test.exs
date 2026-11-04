defmodule CrewImage.KeysTest do
  use ExUnit.Case, async: true

  alias CrewImage.Keys
  alias CrewProtocol.Auth

  test "sign/2 makes what CrewProtocol.Auth.verify_manifest accepts" do
    {public, private} = Auth.generate_keypair()
    bytes = ~s({"version":"0.1.0"}\n)

    sig = Keys.sign(bytes, private)
    assert Auth.verify_manifest(bytes, sig, public) == :ok
    assert Keys.verify(bytes, sig, public) == :ok
    # And the agent's side reads it the same way.
    assert {:ok, <<_::binary-size(64)>>} = Base.decode64(sig)
  end

  test "a changed byte or another key fails" do
    {public, private} = Auth.generate_keypair()
    {other, _} = Auth.generate_keypair()
    bytes = ~s({"version":"0.1.0"}\n)
    sig = Keys.sign(bytes, private)

    assert Keys.verify(bytes <> " ", sig, public) == {:error, :bad_signature}
    assert Keys.verify(bytes, sig, other) == {:error, :bad_signature}
  end

  test "key files: comments and blank lines are skipped, the key is base64" do
    {public, private} = Auth.generate_keypair()

    text = "# a comment\n\n  #{Base.encode64(private)}  \n"
    assert Keys.parse_private(text) == {:ok, private}
    assert Keys.parse_public("# c\n#{Base.encode64(public)}\n") == {:ok, public}

    assert Keys.parse_private("# nothing\n") == {:error, :no_key}
    assert Keys.parse_private(Base.encode64("short")) == {:error, :bad_key}
    assert Keys.parse_private("not base64!") == {:error, :bad_key}

    assert Keys.parse_private("#{Base.encode64(private)}\n#{Base.encode64(private)}\n") ==
             {:error, :bad_key}
  end

  test "the committed test key's halves match, and it's known as the test key" do
    {:ok, private} = Keys.load_private(file: Keys.test_key_path())
    assert Auth.public_key(private) == Keys.test_public_key()
    assert Keys.test_key?(Keys.test_public_key())

    {public, _} = Auth.generate_keypair()
    refute Keys.test_key?(public)
  end

  test "load_private/1 reads an env var or a file, and refuses the test key for a release" do
    {_public, private} = Auth.generate_keypair()
    env = %{"SIGNING_KEY" => Base.encode64(private)}

    assert Keys.load_private(env: "SIGNING_KEY", getenv: &Map.get(env, &1)) == {:ok, private}
    assert Keys.load_private(env: "NOPE", getenv: &Map.get(env, &1)) == {:error, {:unset, "NOPE"}}

    assert {:ok, _} = Keys.load_private(file: Keys.test_key_path())

    assert Keys.load_private(file: Keys.test_key_path(), release: true) ==
             {:error, :test_key_for_release}
  end

  test "fingerprint/1 is OpenSSH's form, as the control plane shows it" do
    assert Keys.fingerprint(Keys.test_public_key()) ==
             "SHA256:vj4DnPcWRn2HCPz3dJiut+9PXO1/RHe0J1LN92r/nRE"
  end
end
