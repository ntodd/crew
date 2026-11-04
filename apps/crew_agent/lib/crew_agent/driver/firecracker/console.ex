defmodule CrewAgent.Driver.Firecracker.Console do
  @moduledoc """
  The console log cap (§11.3). systemd appends the guest's serial console
  to `console.log` (O_APPEND, as root); the agent owns the file and caps
  it: past 8 MiB it keeps the first 4 MiB, a fixed-width marker and a
  rolling last 4 MiB, so the file is never left over 8 MiB.

  Output appended between reading the tail and truncating is lost: the
  console is for boot problems, and crew-guest never writes job output
  to it.
  """

  @head 4 * 1024 * 1024
  @tail 4 * 1024 * 1024

  @doc "The marker between the head and the tail. Its width doesn't depend on `omitted`."
  def marker(omitted) do
    "\n[crew: console truncated, " <>
      String.pad_leading(Integer.to_string(omitted), 20, "0") <> " bytes omitted]\n"
  end

  @doc """
  Caps the console at `path` to `head + tail` bytes. Returns `:ok` when
  there was nothing to do, or `{:truncated, omitted}` with every byte
  dropped so far.
  """
  def cap(path, head \\ @head, tail \\ @tail) do
    marker_len = byte_size(marker(0))
    keep = tail - marker_len

    with {:ok, %File.Stat{type: :regular, size: size}} when size > head + tail <-
           File.lstat(path),
         {:ok, io} <- :file.open(path, [:read, :write, :binary, :raw]) do
      try do
        # What's already gone, from the marker a previous cap left: then
        # the bytes after that marker are the ones dropped now.
        {prior, from} = prior(io, head, marker_len)

        omitted = prior + (size - keep - from)
        {:ok, last} = :file.pread(io, size - keep, keep)
        :ok = :file.pwrite(io, head, marker(omitted) <> last)
        {:ok, _} = :file.position(io, head + tail)
        :ok = :file.truncate(io)
        {:truncated, omitted}
      after
        :file.close(io)
      end
    else
      _ -> :ok
    end
  end

  defp prior(io, head, marker_len) do
    with {:ok, bytes} <- :file.pread(io, head, marker_len),
         [_, n] <-
           Regex.run(~r/\A\n\[crew: console truncated, (\d{20}) bytes omitted\]\n\z/, bytes) do
      {String.to_integer(n), head + marker_len}
    else
      _ -> {0, head}
    end
  end
end
