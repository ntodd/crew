defmodule CrewAgent.Text do
  @moduledoc """
  Keeps text bound for the control plane valid UTF-8.

  Command output is raw bytes: a build step can print Latin-1, a pipe read
  can end in the middle of a character, and trimming output to its tail can
  start in the middle of one. Events are JSON, and one invalid byte makes an
  event that can't be sent at all.
  """

  @doc """
  Replaces invalid UTF-8 in every string in `term`, including those in
  maps, lists and tuples.
  """
  @spec scrub(term()) :: term()
  def scrub(binary) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: String.replace_invalid(binary)
  end

  def scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)

  def scrub(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&scrub/1) |> List.to_tuple()

  def scrub(%_{} = struct), do: struct

  def scrub(map) when is_map(map), do: Map.new(map, fn {k, v} -> {scrub(k), scrub(v)} end)

  def scrub(other), do: other

  @doc """
  Splits `binary` before a character that it cuts off at the end, so the
  rest can wait for the next chunk: `{complete, incomplete_tail}`.
  """
  @spec split_incomplete(binary()) :: {binary(), binary()}
  def split_incomplete(binary) do
    size = byte_size(binary)
    tail = incomplete_tail(binary, size, 1)
    {binary_part(binary, 0, size - tail), binary_part(binary, size - tail, tail)}
  end

  # Looks back at most 3 bytes for the lead byte of the last character, and
  # returns how many bytes to hold back (0 if the character is complete).
  defp incomplete_tail(_binary, size, back) when back > 3 or back > size, do: 0

  defp incomplete_tail(binary, size, back) do
    byte = :binary.at(binary, size - back)

    cond do
      Bitwise.band(byte, 0xC0) == 0x80 -> incomplete_tail(binary, size, back + 1)
      sequence_length(byte) > back -> back
      true -> 0
    end
  end

  defp sequence_length(byte) when byte in 0xC0..0xDF, do: 2
  defp sequence_length(byte) when byte in 0xE0..0xEF, do: 3
  defp sequence_length(byte) when byte in 0xF0..0xF7, do: 4
  defp sequence_length(_byte), do: 1

  @doc """
  Drops the continuation bytes (at most 3) at the start of `binary`, as
  when its start cut a character in two.
  """
  @spec trim_leading_partial(binary()) :: binary()
  def trim_leading_partial(binary, dropped \\ 0)

  def trim_leading_partial(<<byte, rest::binary>> = binary, dropped) when dropped < 3 do
    if Bitwise.band(byte, 0xC0) == 0x80,
      do: trim_leading_partial(rest, dropped + 1),
      else: binary
  end

  def trim_leading_partial(binary, _dropped), do: binary
end
