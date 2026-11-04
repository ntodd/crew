defmodule CrewProtocol.AuthTest do
  use ExUnit.Case, async: true

  alias CrewProtocol.Auth

  setup do
    {public, private} = Auth.generate_keypair()
    %{public: public, private: private}
  end

  describe "connect headers" do
    test "verify with the right key", %{public: public, private: private} do
      headers = Auth.connect_headers("box-1", private, now: 1000)
      lookup = fn "box-1" -> {:ok, public} end

      assert {:ok, %{agent_id: "box-1", ts: 1000, nonce: nonce}} =
               Auth.verify_connect_headers(headers, lookup, now: 1010)

      assert byte_size(nonce) >= 16
    end

    test "refuse a clock more than 60 s off", %{public: public, private: private} do
      headers = Auth.connect_headers("box-1", private, now: 1000)

      assert {:error, :clock_skew} =
               Auth.verify_connect_headers(headers, fn _ -> {:ok, public} end, now: 1061)
    end

    test "refuse another key", %{private: private} do
      {other, _} = Auth.generate_keypair()
      headers = Auth.connect_headers("box-1", private, now: 1000)

      assert {:error, :bad_signature} =
               Auth.verify_connect_headers(headers, fn _ -> {:ok, other} end, now: 1000)
    end

    test "refuse a signature moved to another agent id", %{public: public, private: private} do
      headers = Auth.connect_headers("box-1", private, now: 1000)
      headers = Map.put(headers, "x-crew-agent-id", "box-2")

      assert {:error, :bad_signature} =
               Auth.verify_connect_headers(headers, fn _ -> {:ok, public} end, now: 1000)
    end

    test "unknown agents and malformed headers", %{private: private} do
      headers = Auth.connect_headers("box-1", private, now: 1000)

      assert {:error, :unknown_agent} =
               Auth.verify_connect_headers(headers, fn _ -> :error end, now: 1000)

      assert {:error, :malformed} = Auth.verify_connect_headers(%{}, fn _ -> :error end)
      assert {:error, :malformed} = Auth.verify_connect_headers(nil, fn _ -> :error end)
    end

    test "the headers are Crew's" do
      assert Auth.header_names() ==
               ~w(x-crew-agent-id x-crew-agent-ts x-crew-agent-nonce x-crew-agent-sig)
    end
  end

  describe "release signatures" do
    test "cover version, target and sha256", %{public: public, private: private} do
      sha = String.duplicate("a", 64)
      sig = Auth.sign_release("1.2.3", "linux-amd64", sha, private)
      assert :ok = Auth.verify_release("1.2.3", "linux-amd64", sha, sig, public)

      assert {:error, :bad_signature} =
               Auth.verify_release("1.2.4", "linux-amd64", sha, sig, public)

      assert {:error, :bad_signature} =
               Auth.verify_release("1.2.3", "darwin-arm64", sha, sig, public)

      assert {:error, :bad_signature} =
               Auth.verify_release("1.2.3", "linux-amd64", sha, "!!", public)
    end

    # The box's first install checks the signature with openssl in a
    # shell script (Crew.Boxes.Flatcar), and CI's sign job may sign with
    # openssl too: both rebuild these exact bytes.
    test "sign these exact bytes, with no trailing newline", %{public: public, private: private} do
      sha = String.duplicate("a", 64)

      assert Auth.release_message("1.2.3", "linux-amd64", sha) ==
               "crew-release-v1\n1.2.3\nlinux-amd64\n" <> sha

      {:ok, sig} = Auth.sign_release("1.2.3", "linux-amd64", sha, private) |> Base.decode64()

      assert :crypto.verify(
               :eddsa,
               :none,
               "crew-release-v1\n1.2.3\nlinux-amd64\n" <> sha,
               sig,
               [public, :ed25519]
             )
    end

    test "refuse a field with a newline in it", %{public: public, private: private} do
      sha = String.duplicate("a", 64)
      sig = Auth.sign_release("1.2.3", "linux-amd64", sha, private)

      assert {:error, :bad_signature} =
               Auth.verify_release("1.2.3\nlinux-amd64", "", sha, sig, public)

      assert {:error, :bad_signature} =
               Auth.verify_release("1.2.3", "linux-amd64", sha <> "\n", sig, public)

      assert_raise ArgumentError, fn -> Auth.release_message("1.2.3\n", "linux-amd64", sha) end
    end
  end

  describe "manifest signatures" do
    test "cover the exact bytes", %{public: public, private: private} do
      manifest = ~s({"version":"1.0.0","arch":"arm64"})
      sig = Auth.sign_manifest(manifest, private)
      assert :ok = Auth.verify_manifest(manifest, sig, public)
      assert {:error, :bad_signature} = Auth.verify_manifest(manifest <> " ", sig, public)
    end

    test "can't be confused with a release signature", %{public: public, private: private} do
      sha = String.duplicate("a", 64)
      sig = Auth.sign_release("1.2.3", "linux-amd64", sha, private)

      assert {:error, :bad_signature} =
               Auth.verify_manifest("crew-release-v1\n1.2.3\nlinux-amd64\n#{sha}", sig, public)
    end
  end

  test "fingerprints are stable, short and colon-free", %{public: public} do
    fp = Auth.fingerprint(public)
    assert fp == Auth.fingerprint(public)
    assert fp =~ ~r/\ASHA256:[A-Za-z0-9+\/]{43}\z/
  end
end
