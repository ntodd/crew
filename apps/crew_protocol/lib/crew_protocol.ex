defmodule CrewProtocol do
  @moduledoc """
  The contract between Crew's control plane, its agents and its guests:
  commands, events, guest API bodies, labels and sizes.

  Every side depends on this library, so a message one side builds is
  validated by the same code on the other.
  """

  alias CrewProtocol.Schema

  @version 1

  @doc "The protocol version this build speaks."
  def version, do: @version

  @doc "The control plane accepts the current protocol and the one before it (§10.5)."
  def compatible?(version) when is_integer(version), do: version in [@version, @version - 1]
  def compatible?(_), do: false

  @join_spec [
    agent_version: {:version, required: true},
    protocol_version: {:integer, required: true},
    box_name: {:box_name, required: true},
    os: {{:enum, ~w(linux darwin)}, required: true},
    arch: {{:enum, ~w(x64 arm64)}, required: true},
    boot_id: {:uuid, required: true},
    in_flight: {{:list, :uuid}, default: [], max: 1000}
  ]

  @doc "Validates the payload an agent sends when it joins its topic."
  def cast_join(payload), do: Schema.cast(payload, @join_spec)

  def dump_join(join), do: Schema.dump(join, @join_spec)

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "Whether `value` is a lowercase UUID, as every id on the wire is."
  def uuid?(value) when is_binary(value), do: Regex.match?(@uuid, value)
  def uuid?(_), do: false

  @doc "A random (v4) UUID."
  def uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    format(<<a::48, 4::4, b::12, 2::2, c::62>>)
  end

  @doc "A time-ordered (v7) UUID, for row ids (§22)."
  def uuid7(ms \\ System.os_time(:millisecond)) do
    <<_::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    format(<<ms::48, 7::4, b::12, 2::2, c::62>>)
  end

  defp format(<<u0::32, u1::16, u2::16, u3::16, u4::48>>) do
    [u0, u1, u2, u3, u4]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {v, n} ->
      v |> Integer.to_string(16) |> String.pad_leading(n, "0")
    end)
    |> String.downcase()
  end
end
