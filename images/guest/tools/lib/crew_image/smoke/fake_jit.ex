defmodule CrewImage.Smoke.FakeJIT do
  @moduledoc """
  A JIT runner config shaped like GitHub's `encoded_jit_config`: base64 of
  a JSON object whose values are the runner's settings files, each base64
  again. Its `.runner` has `DisableUpdate: true`, which crew-guest checks
  before it starts the runner (§13.5 step 7).

  Nothing in it is registered with GitHub: the runner reads it, starts,
  and fails to authenticate. Getting that far is what the smoke boot
  checks. The RSA key is real (the runner parses it) and thrown away.
  """

  def build(opts) do
    name = Keyword.fetch!(opts, :name)

    runner = %{
      "AgentId" => 1,
      "AgentName" => name,
      "PoolId" => 1,
      "PoolName" => "Default",
      "DisableUpdate" => true,
      "Ephemeral" => true,
      "ServerUrl" => "https://pipelines.actions.githubusercontent.com/crew-smoke/",
      "GitHubUrl" => "https://github.com/ntodd/crew",
      "WorkFolder" => "_work"
    }

    credentials = %{
      "Scheme" => "OAuth",
      "Data" => %{
        "clientId" => uuid(),
        "authorizationUrl" =>
          "https://vstoken.actions.githubusercontent.com/_apis/oauth2/token/crew-smoke",
        "requireFipsCryptography" => "False"
      }
    }

    files = %{
      ".runner" => encode(runner),
      ".credentials" => encode(credentials),
      ".credentials_rsaparams" => encode(rsa_params())
    }

    encode(files)
  end

  defp encode(map), do: map |> Jason.encode!() |> Base.encode64()

  # .NET's RSAParameters, as the runner stores them.
  defp rsa_params do
    {:RSAPrivateKey, _, n, e, d, p, q, dp, dq, qinv, _} =
      :public_key.generate_key({:rsa, 2048, 65_537})

    b = &(&1 |> :binary.encode_unsigned() |> Base.encode64())

    %{
      "d" => b.(d),
      "dp" => b.(dp),
      "dq" => b.(dq),
      "exponent" => b.(e),
      "inverseQ" => b.(qinv),
      "modulus" => b.(n),
      "p" => b.(p),
      "q" => b.(q)
    }
  end

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
