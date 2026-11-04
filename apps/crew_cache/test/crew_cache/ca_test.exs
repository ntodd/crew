defmodule CrewCache.CATest do
  use ExUnit.Case, async: true

  alias CrewCache.CA
  alias CrewCache.CA.Certs

  @moduletag :tmp_dir
  @ip {10, 199, 0, 1}

  describe "the chain (§15.4)" do
    setup do
      %{chain: Certs.chain(@ip)}
    end

    test "has no root key: only the intermediate's", %{chain: chain} do
      assert Map.keys(chain) |> Enum.sort() == [:intermediate, :intermediate_key, :root]
    end

    test "the root is a self-signed ECDSA P-256 CA for 10 years", %{chain: chain} do
      root = Certs.decode(chain.root)
      assert :public_key.pkix_is_self_signed(chain.root)
      assert {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}} = Certs.curve(root)
      assert Certs.ext(root, :basic_constraints) == {true, {true, :asn1_NOVALUE}}

      {not_before, not_after} = Certs.validity(root)
      assert_in_delta DateTime.diff(not_after, not_before, :day), 3652, 2
    end

    test "the intermediate is signed by the root", %{chain: chain} do
      assert :public_key.pkix_is_issuer(chain.intermediate, chain.root)
      root_key = chain.root |> Certs.decode() |> Certs.public_key()
      assert :public_key.pkix_verify(chain.intermediate, root_key)
      assert Certs.ext(Certs.decode(chain.intermediate), :basic_constraints) == {true, {true, 0}}
    end

    test "the intermediate's name constraints are critical: this IP, and no DNS names",
         %{chain: chain} do
      assert {true,
              %{
                permitted: [{:iPAddress, <<10, 199, 0, 1, 255, 255, 255, 255>>}],
                excluded: [{:dNSName, ~c""}]
              }} =
               Certs.ext(Certs.decode(chain.intermediate), :name_constraints)
    end

    test "a leaf is for the IP, 30 days, signed by the intermediate", %{chain: chain} do
      {leaf, key} = Certs.leaf(chain, @ip)
      cert = Certs.decode(leaf)
      assert :public_key.pkix_is_issuer(leaf, chain.intermediate)
      assert Certs.ext(cert, :subject_alt_name) == {false, [{:iPAddress, <<10, 199, 0, 1>>}]}
      assert {_, [{1, 3, 6, 1, 5, 5, 7, 3, 1}]} = Certs.ext(cert, :ext_key_usage)
      assert match?({:ECPrivateKey, _, _, _, _, _}, key)

      {not_before, not_after} = Certs.validity(cert)
      assert DateTime.diff(not_after, not_before, :day) == 30
    end

    # OTP 29 can't validate the path itself: pubkey_cert's iPAddress
    # constraint clause is spelt `ipAdress` and crashes. Go and OpenSSL
    # (below) check the whole chain.
    test "each certificate is signed by the one above it", %{chain: chain} do
      {leaf, _key} = Certs.leaf(chain, @ip)
      inter_key = chain.intermediate |> Certs.decode() |> Certs.public_key()
      assert :public_key.pkix_verify(leaf, inter_key)
      refute :public_key.pkix_verify(leaf, chain.root |> Certs.decode() |> Certs.public_key())
    end
  end

  describe "openssl verify" do
    setup %{tmp_dir: dir} do
      chain = Certs.chain(@ip)
      File.write!(Path.join(dir, "root.pem"), Certs.pem(chain.root))
      File.write!(Path.join(dir, "intermediate.pem"), Certs.pem(chain.intermediate))
      %{chain: chain}
    end

    @tag :openssl
    test "accepts the leaf", %{chain: chain, tmp_dir: dir} do
      {leaf, _} = Certs.leaf(chain, @ip)
      assert {out, 0} = openssl_verify(dir, leaf, ["-verify_ip", "10.199.0.1"])
      assert out =~ "OK"
    end

    @tag :openssl
    test "refuses a leaf for a DNS name", %{chain: chain, tmp_dir: dir} do
      {leaf, _} = Certs.leaf(chain, [{:dNSName, ~c"ghcr.io"}])
      assert {out, code} = openssl_verify(dir, leaf, [])
      assert code != 0
      assert out =~ "excluded subtree violation"
    end

    @tag :openssl
    test "refuses a leaf for another IP", %{chain: chain, tmp_dir: dir} do
      {leaf, _} = Certs.leaf(chain, {10, 199, 0, 2})
      assert {out, code} = openssl_verify(dir, leaf, [])
      assert code != 0
      assert out =~ "permitted subtree violation"
    end

    @tag :openssl
    test "shows the constraints as critical", %{tmp_dir: dir} do
      {out, 0} =
        System.cmd("openssl", [
          "x509",
          "-noout",
          "-text",
          "-in",
          Path.join(dir, "intermediate.pem")
        ])

      assert out =~ "X509v3 Name Constraints: critical"
      assert out =~ ~r/Permitted:\s+IP:10.199.0.1\/255.255.255.255/
      assert out =~ ~r/Excluded:\s+DNS:\s*\n/
    end
  end

  describe "Go's crypto/x509" do
    @describetag :go
    setup %{tmp_dir: dir} do
      chain = Certs.chain(@ip)
      {good, _} = Certs.leaf(chain, @ip)
      {dns, _} = Certs.leaf(chain, [{:iPAddress, <<10, 199, 0, 1>>}, {:dNSName, ~c"ghcr.io"}])

      for {name, der} <- [
            root: chain.root,
            intermediate: chain.intermediate,
            good: good,
            dns: dns
          ] do
        File.write!(Path.join(dir, "#{name}.pem"), Certs.pem(der))
      end

      File.write!(Path.join(dir, "verify.go"), go_program())
      :ok
    end

    test "verifies the leaf for the IP and refuses one with a DNS name", %{tmp_dir: dir} do
      {out, code} =
        System.cmd("go", ["run", "verify.go"],
          cd: dir,
          stderr_to_stdout: true,
          env: [{"GOFLAGS", "-mod=mod"}, {"GO111MODULE", "off"}]
        )

      assert code == 0, out
      assert out =~ "good: ok"
      assert out =~ ~r/dns: .*(excluded|constraint)/
    end
  end

  describe "the CA process" do
    test "creates the chain once, keeping only the intermediate's key", %{tmp_dir: dir} do
      pid = start_supervised!({CA, dir: dir, ip: @ip})
      root = CA.root_pem(pid)
      files = File.ls!(Path.join(dir, "ca")) |> Enum.sort()
      assert files == ~w(intermediate.key intermediate.pem leaf.key leaf.pem root.pem)

      for key <- ~w(intermediate.key leaf.key) do
        assert %{mode: mode} = File.stat!(Path.join([dir, "ca", key]))
        assert Bitwise.band(mode, 0o777) == 0o600
      end

      root_public = root |> Certs.from_pem() |> Certs.decode() |> Certs.public_key()

      for key <- ~w(intermediate.key leaf.key) do
        refute Certs.key_from_pem(File.read!(Path.join([dir, "ca", key]))) |> Certs.public_of() ==
                 root_public
      end

      stop_supervised!(CA)
      pid = start_supervised!({CA, dir: dir, ip: @ip})
      assert CA.root_pem(pid) == root
    end

    test "the leaf file carries the intermediate", %{tmp_dir: dir} do
      start_supervised!({CA, dir: dir, ip: @ip})
      %{certfile: certfile} = CA.tls_files()
      pems = certfile |> File.read!() |> :public_key.pem_decode()
      assert length(pems) == 2
      [{_, leaf, _}, {_, intermediate, _}] = pems
      assert :public_key.pkix_is_issuer(leaf, intermediate)
    end

    test "replaces a leaf older than a day", %{tmp_dir: dir} do
      start_supervised!({CA, dir: dir, ip: @ip})
      stop_supervised!(CA)

      chain = CA.load_chain(dir)
      old = DateTime.add(DateTime.utc_now(), -2, :day)
      {leaf, key} = Certs.leaf(chain, @ip, old)
      CA.write_leaf(dir, chain, leaf, key)

      start_supervised!({CA, dir: dir, ip: @ip})
      %{certfile: certfile} = CA.tls_files()
      [{_, new_leaf, _} | _] = certfile |> File.read!() |> :public_key.pem_decode()
      {not_before, _} = new_leaf |> Certs.decode() |> Certs.validity()
      assert DateTime.diff(DateTime.utc_now(), not_before, :hour) < 2
    end

    test "rotate/0 regenerates the whole chain", %{tmp_dir: dir} do
      pid = start_supervised!({CA, dir: dir, ip: @ip})
      before = CA.root_pem(pid)
      inter = File.read!(Path.join([dir, "ca", "intermediate.pem"]))
      :ok = CA.rotate()
      refute CA.root_pem(pid) == before
      refute File.read!(Path.join([dir, "ca", "intermediate.pem"])) == inter
    end

    test "a new listen IP regenerates the chain", %{tmp_dir: dir} do
      pid = start_supervised!({CA, dir: dir, ip: @ip})
      before = CA.root_pem(pid)
      stop_supervised!(CA)
      pid = start_supervised!({CA, dir: dir, ip: {10, 199, 0, 9}})
      refute CA.root_pem(pid) == before

      assert {true, %{permitted: [{:iPAddress, <<10, 199, 0, 9, 255, 255, 255, 255>>}]}} =
               CA.load_chain(dir).intermediate |> Certs.decode() |> Certs.ext(:name_constraints)

      # The leaf is replaced with the chain: every intermediate has the
      # same name, so a name check alone would keep the old one.
      {leaf, _key} = served_leaf(dir)
      assert verifies?(leaf, CA.load_chain(dir).intermediate)

      assert Certs.ext(Certs.decode(leaf), :subject_alt_name) ==
               {false, [{:iPAddress, <<10, 199, 0, 9>>}]}
    end

    test "rotate/0 replaces the leaf too", %{tmp_dir: dir} do
      start_supervised!({CA, dir: dir, ip: @ip})
      :ok = CA.rotate()
      {leaf, _} = served_leaf(dir)
      assert verifies?(leaf, CA.load_chain(dir).intermediate)
    end

    test "a leaf from another chain with the same names is replaced at start", %{tmp_dir: dir} do
      start_supervised!({CA, dir: dir, ip: @ip})
      stop_supervised!(CA)

      chain = CA.load_chain(dir)
      {stranger, key} = Certs.leaf(Certs.chain(@ip), @ip)
      assert :public_key.pkix_is_issuer(stranger, chain.intermediate)
      CA.write_leaf(dir, chain, stranger, key)

      start_supervised!({CA, dir: dir, ip: @ip})
      {leaf, _} = served_leaf(dir)
      refute leaf == stranger
      assert verifies?(leaf, chain.intermediate)
    end

    test "a leaf whose key doesn't match is replaced at start", %{tmp_dir: dir} do
      start_supervised!({CA, dir: dir, ip: @ip})
      stop_supervised!(CA)
      {leaf, _} = served_leaf(dir)
      {_, other_key} = Certs.leaf(CA.load_chain(dir), @ip)
      File.write!(Path.join([dir, "ca", "leaf.key"]), Certs.key_pem(other_key))

      start_supervised!({CA, dir: dir, ip: @ip})
      {new_leaf, new_key} = served_leaf(dir)
      refute new_leaf == leaf
      assert Certs.public_of(new_key) == new_leaf |> Certs.decode() |> Certs.public_key()
    end
  end

  defp served_leaf(dir) do
    [{_, leaf, _} | _] =
      File.read!(Path.join([dir, "ca", "leaf.pem"])) |> :public_key.pem_decode()

    {leaf, File.read!(Path.join([dir, "ca", "leaf.key"])) |> Certs.key_from_pem()}
  end

  defp verifies?(leaf, intermediate),
    do: :public_key.pkix_verify(leaf, intermediate |> Certs.decode() |> Certs.public_key())

  defp openssl_verify(dir, leaf, extra) do
    leaf_path = Path.join(dir, "leaf-#{System.unique_integer([:positive])}.pem")
    File.write!(leaf_path, Certs.pem(leaf))

    System.cmd(
      "openssl",
      [
        "verify",
        "-CAfile",
        Path.join(dir, "root.pem"),
        "-untrusted",
        Path.join(dir, "intermediate.pem")
      ] ++
        extra ++ [leaf_path],
      stderr_to_stdout: true
    )
  end

  defp go_program do
    """
    package main

    import (
    \t"crypto/x509"
    \t"encoding/pem"
    \t"fmt"
    \t"os"
    )

    func load(name string) *x509.Certificate {
    \tdata, err := os.ReadFile(name + ".pem")
    \tif err != nil {
    \t\tpanic(err)
    \t}
    \tblock, _ := pem.Decode(data)
    \tcert, err := x509.ParseCertificate(block.Bytes)
    \tif err != nil {
    \t\tpanic(err)
    \t}
    \treturn cert
    }

    func main() {
    \troots := x509.NewCertPool()
    \troots.AddCert(load("root"))
    \tinter := x509.NewCertPool()
    \tinter.AddCert(load("intermediate"))
    \topts := x509.VerifyOptions{Roots: roots, Intermediates: inter}
    \tfor _, name := range []string{"good", "dns"} {
    \t\tif _, err := load(name).Verify(opts); err != nil {
    \t\t\tfmt.Printf("%s: %v\\n", name, err)
    \t\t} else {
    \t\t\tfmt.Printf("%s: ok\\n", name)
    \t\t}
    \t}
    }
    """
  end
end
