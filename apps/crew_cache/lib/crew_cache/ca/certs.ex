defmodule CrewCache.CA.Certs do
  @moduledoc """
  Building the per-box chain (§15.4) with OTP's `:public_key`:

  - a root (ECDSA P-256, 10 years) whose key is never returned, so it's
    gone as soon as `chain/1` does;
  - an intermediate signed by it, with a critical Name Constraints
    extension. Design A permits the listen IP (`iPAddress` ip/32) and
    excludes every DNS name, encoded as an excluded `dNSName` of "": in
    RFC 5280 a DNS constraint matches any name made by adding labels on
    its left, so the empty name matches them all, and Go and OpenSSL
    both read it that way;
  - leaves for the listen IP (an IP SAN, no DNS SAN and no hostname-like
    CN), 30 days, signed by the intermediate.

  Design B would put the intercepted hostnames in `permitted` and
  `0.0.0.0/0` and `::/0` in `excluded`: `name_constraints/1` is where.
  """

  require Record

  @hrl "public_key/include/public_key.hrl"
  for name <- [
        :OTPTBSCertificate,
        :OTPCertificate,
        :OTPSubjectPublicKeyInfo,
        :PublicKeyAlgorithm,
        :SignatureAlgorithm,
        :Validity,
        :Extension,
        :BasicConstraints,
        :NameConstraints,
        :GeneralSubtree,
        :AuthorityKeyIdentifier,
        :AttributeTypeAndValue,
        :ECPrivateKey,
        :ECPoint
      ] do
    Record.defrecordp(
      String.to_atom("r_" <> Macro.underscore(Atom.to_string(name))),
      name,
      Record.extract(name, from_lib: @hrl)
    )
  end

  @p256 {1, 2, 840, 10_045, 3, 1, 7}
  @ec_public_key {1, 2, 840, 10_045, 2, 1}
  @ecdsa_sha256 {1, 2, 840, 10_045, 4, 3, 2}
  @common_name {2, 5, 4, 3}
  @organization {2, 5, 4, 10}

  @basic_constraints {2, 5, 29, 19}
  @key_usage {2, 5, 29, 15}
  @ext_key_usage {2, 5, 29, 37}
  @subject_alt_name {2, 5, 29, 17}
  @subject_key_id {2, 5, 29, 14}
  @authority_key_id {2, 5, 29, 35}
  @name_constraints {2, 5, 29, 30}
  @server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}

  @root_days 3652
  @leaf_days 30

  @type chain :: %{root: binary, intermediate: binary, intermediate_key: tuple}

  @doc "A new root and intermediate for `ip`. The root key isn't kept."
  @spec chain(:inet.ip4_address(), DateTime.t()) :: chain
  def chain(ip, now \\ DateTime.utc_now()) do
    root_key = new_key()
    root_name = name("Crew registry cache root")

    root =
      sign(
        root_key,
        root_name,
        root_name,
        root_key,
        period(now, @root_days),
        [
          ext(@basic_constraints, true, r_basic_constraints(cA: true)),
          ext(@key_usage, true, [:keyCertSign, :cRLSign]),
          ext(@subject_key_id, false, key_id(root_key))
        ]
      )

    inter_key = new_key()

    intermediate =
      sign(
        root_key,
        root_name,
        name("Crew registry cache intermediate"),
        inter_key,
        period(now, @root_days),
        [
          ext(@basic_constraints, true, r_basic_constraints(cA: true, pathLenConstraint: 0)),
          ext(@key_usage, true, [:keyCertSign, :cRLSign]),
          ext(@name_constraints, true, name_constraints({:ip, ip})),
          ext(@subject_key_id, false, key_id(inter_key)),
          ext(
            @authority_key_id,
            false,
            r_authority_key_identifier(keyIdentifier: key_id(root_key))
          )
        ]
      )

    %{root: root, intermediate: intermediate, intermediate_key: inter_key}
  end

  @doc """
  The constraints for a design: `{:ip, ip}` (Design A) or `{:dns, names}`
  (Design B, not built).
  """
  def name_constraints({:ip, {a, b, c, d}}) do
    r_name_constraints(
      permittedSubtrees: [subtree({:iPAddress, <<a, b, c, d, 255, 255, 255, 255>>})],
      excludedSubtrees: [subtree({:dNSName, ~c""})]
    )
  end

  defp subtree(base), do: r_general_subtree(base: base, minimum: 0)

  @doc """
  A leaf for `ip` (or, for tests, a list of SANs), signed by the
  intermediate. Returns `{der, key}`.
  """
  def leaf(chain, ip_or_sans, now \\ DateTime.utc_now())

  def leaf(chain, {a, b, c, d}, now), do: leaf(chain, [{:iPAddress, <<a, b, c, d>>}], now)

  def leaf(%{intermediate: inter, intermediate_key: inter_key}, sans, now) when is_list(sans) do
    key = new_key()

    der =
      sign(
        inter_key,
        subject(inter),
        name("Crew registry cache"),
        key,
        period(now, @leaf_days, 0),
        [
          ext(@basic_constraints, true, r_basic_constraints(cA: false)),
          ext(@key_usage, true, [:digitalSignature]),
          ext(@ext_key_usage, false, [@server_auth]),
          ext(@subject_alt_name, false, sans),
          ext(@subject_key_id, false, key_id(key)),
          ext(
            @authority_key_id,
            false,
            r_authority_key_identifier(keyIdentifier: key_id(inter_key))
          )
        ]
      )

    {der, key}
  end

  # -- building -------------------------------------------------------------

  defp new_key, do: :public_key.generate_key({:namedCurve, @p256})

  defp sign(issuer_key, issuer, subject, subject_key, validity, extensions) do
    tbs =
      r_otptbs_certificate(
        version: :v3,
        serialNumber: serial(),
        signature: r_signature_algorithm(algorithm: @ecdsa_sha256),
        issuer: issuer,
        validity: validity,
        subject: subject,
        subjectPublicKeyInfo:
          r_otp_subject_public_key_info(
            algorithm:
              r_public_key_algorithm(algorithm: @ec_public_key, parameters: {:namedCurve, @p256}),
            subjectPublicKey: r_ec_point(point: r_ec_private_key(subject_key, :publicKey))
          ),
        extensions: extensions
      )

    :public_key.pkix_sign(tbs, issuer_key)
  end

  defp serial do
    <<n::unsigned-128>> = :crypto.strong_rand_bytes(16)
    # Positive and at most 20 octets (RFC 5280 §4.1.2.2).
    Bitwise.band(n, Bitwise.bsl(1, 126) - 1) + 1
  end

  defp name(cn) do
    {:rdnSequence,
     [
       [r_attribute_type_and_value(type: @organization, value: {:utf8String, "Crew"})],
       [r_attribute_type_and_value(type: @common_name, value: {:utf8String, cn})]
     ]}
  end

  # Leaves start an hour back, for clock skew; CAs a day back.
  defp period(now, days, back_hours \\ 24) do
    from = DateTime.add(now, -back_hours, :hour) |> DateTime.truncate(:second)
    to = DateTime.add(from, days, :day)
    r_validity(notBefore: asn1_time(from), notAfter: asn1_time(to))
  end

  defp asn1_time(%DateTime{year: year} = dt) when year < 2050 do
    {:utcTime, Calendar.strftime(dt, "%y%m%d%H%M%SZ") |> String.to_charlist()}
  end

  defp asn1_time(dt),
    do: {:generalTime, Calendar.strftime(dt, "%Y%m%d%H%M%SZ") |> String.to_charlist()}

  defp ext(id, critical, value), do: r_extension(extnID: id, critical: critical, extnValue: value)

  defp key_id(key) do
    :crypto.hash(:sha, r_ec_private_key(key, :publicKey)) |> binary_part(0, 20)
  end

  # -- reading --------------------------------------------------------------

  @doc "The OTP form of a DER certificate."
  def decode(der), do: :public_key.pkix_decode_cert(der, :otp)

  def pem(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  def from_pem(pem) do
    [{:Certificate, der, _} | _] = :public_key.pem_decode(pem)
    der
  end

  def key_pem(key), do: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])

  def key_from_pem(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  @doc "The subject of a DER certificate, as the issuer of what it signs."
  def subject(der) do
    r_otp_certificate(tbsCertificate: tbs) = decode(der)
    r_otptbs_certificate(tbs, :subject)
  end

  def curve(r_otp_certificate(tbsCertificate: tbs)) do
    r_otptbs_certificate(tbs, :subjectPublicKeyInfo)
    |> r_otp_subject_public_key_info(:algorithm)
    |> r_public_key_algorithm(:parameters)
  end

  @doc "The public key in a certificate, for `:public_key.pkix_verify/2`."
  def public_key(r_otp_certificate(tbsCertificate: tbs) = cert) do
    point =
      r_otptbs_certificate(tbs, :subjectPublicKeyInfo)
      |> r_otp_subject_public_key_info(:subjectPublicKey)

    {point, curve(cert)}
  end

  @doc "The public half of a private key, comparable with `public_key/1`."
  def public_of(key) do
    {r_ec_point(point: r_ec_private_key(key, :publicKey)), r_ec_private_key(key, :parameters)}
  end

  def validity(r_otp_certificate(tbsCertificate: tbs)) do
    r_validity(notBefore: from, notAfter: to) = r_otptbs_certificate(tbs, :validity)
    {to_datetime(from), to_datetime(to)}
  end

  defp to_datetime({:utcTime, text}) do
    <<yy::binary-2, rest::binary>> = to_string(text)
    to_datetime({:generalTime, "20" <> yy <> rest})
  end

  defp to_datetime({:generalTime, text}) do
    <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, "Z">> =
      to_string(text)

    {:ok, dt, 0} = DateTime.from_iso8601("#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z")
    dt
  end

  @doc """
  An extension's `{critical, value}`, simplified for the ones this
  module writes, or nil.
  """
  def ext(r_otp_certificate(tbsCertificate: tbs), which) do
    id =
      Map.fetch!(
        %{
          basic_constraints: @basic_constraints,
          name_constraints: @name_constraints,
          subject_alt_name: @subject_alt_name,
          ext_key_usage: @ext_key_usage,
          key_usage: @key_usage
        },
        which
      )

    tbs
    |> r_otptbs_certificate(:extensions)
    |> Enum.find_value(fn
      r_extension(extnID: ^id, critical: critical, extnValue: value) ->
        {critical, simplify(value)}

      _ ->
        nil
    end)
  end

  defp simplify(r_basic_constraints(cA: ca, pathLenConstraint: len)), do: {ca, len}

  defp simplify(r_name_constraints(permittedSubtrees: permitted, excludedSubtrees: excluded)) do
    bases = fn
      :asn1_NOVALUE -> []
      trees -> Enum.map(trees, &r_general_subtree(&1, :base))
    end

    %{permitted: bases.(permitted), excluded: bases.(excluded)}
  end

  defp simplify(value), do: value
end
