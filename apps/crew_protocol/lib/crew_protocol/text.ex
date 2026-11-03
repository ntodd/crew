defmodule CrewProtocol.Text do
  @moduledoc "Byte-capped, wire-safe text."

  @doc """
  Cuts `text` to at most `max` bytes without splitting a UTF-8 character.
  Returns `{text, truncated?}`.
  """
  @spec cut(binary(), non_neg_integer()) :: {binary(), boolean()}
  def cut(text, max) when byte_size(text) <= max, do: {text, false}

  def cut(text, max) do
    {back_to_boundary(binary_part(text, 0, max)), true}
  end

  # Drops the bytes of a character the cut split: at most 3 continuation
  # bytes (10xxxxxx) and the lead byte before them.
  defp back_to_boundary(bin) do
    if String.valid?(bin), do: bin, else: back_to_boundary(drop_last(bin), 3)
  end

  defp back_to_boundary(bin, 0), do: bin

  defp back_to_boundary(bin, n) do
    if String.valid?(bin), do: bin, else: back_to_boundary(drop_last(bin), n - 1)
  end

  defp drop_last(<<>>), do: <<>>
  defp drop_last(bin), do: binary_part(bin, 0, byte_size(bin) - 1)

  @doc "Replaces bytes that aren't UTF-8, and NULs, with U+FFFD."
  @spec scrub(binary()) :: String.t()
  def scrub(bin) when is_binary(bin) do
    bin |> String.replace_invalid() |> String.replace(<<0>>, "�")
  end
end
