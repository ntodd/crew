defmodule CrewAgent.SafeFS do
  @moduledoc """
  Writes a file so that nothing reads it half-written and a symlink at the
  destination is replaced, not written through: `write_atomic/3` creates
  a fresh temp file with O_EXCL and renames it into place.
  """

  @doc """
  Writes `content` to `path` by creating a new temp file next to it and
  renaming it over the destination. The directory must be one the agent
  owns. The data is synced before the rename, so a power cut can leave
  the old file or the new one, never an empty one.
  """
  @spec write_atomic(Path.t(), iodata(), non_neg_integer()) :: :ok | {:error, term()}
  def write_atomic(path, content, mode) do
    tmp = Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{random()}")

    with {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]),
         :ok <- File.chmod(tmp, mode),
         :ok <- write_and_close(io, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  defp write_and_close(io, content) do
    with :ok <- IO.binwrite(io, content), do: :file.sync(io)
  after
    File.close(io)
  end

  defp random, do: 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
