defmodule Crew.GitHub.JWT do
  @moduledoc "RS256 JWTs that authenticate as the GitHub App itself."

  @doc "A JWT valid for nine minutes (GitHub's limit is ten), backdated a minute for clock drift."
  def app_token(issuer, private_key_pem, now \\ System.system_time(:second)) do
    [entry | _] = :public_key.pem_decode(private_key_pem)
    key = :public_key.pem_entry_decode(entry)

    header = encode(%{"alg" => "RS256", "typ" => "JWT"})
    claims = encode(%{"iat" => now - 60, "exp" => now + 540, "iss" => to_string(issuer)})
    signing_input = header <> "." <> claims
    signature = :public_key.sign(signing_input, :sha256, key)

    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode(map), do: map |> JSON.encode!() |> Base.url_encode64(padding: false)
end
