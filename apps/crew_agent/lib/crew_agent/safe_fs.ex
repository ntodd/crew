defmodule CrewAgent.SafeFS do
  @moduledoc """
  File operations on directories the agent doesn't fully control.

  An environment's workspace is bind-mounted into its containers, so
  anything running in them can replace a file the agent is about to read
  or write with a symlink to somewhere else on the box: the agent's own
  private key, another environment's secrets, a shell profile. Every read
  and write the agent makes under a workspace goes through here.

  - `resolve/2` and `read/3` follow symlinks only while they stay under
    the root.
  - `ensure_dir/2` refuses symlinked parents that lead out of the root and
    replaces (never follows) a symlink at the final component.
  - `real_path/1` says where a path on the box really leads, for checking
    what Docker will mount.
  - `write_atomic/3` creates a fresh temp file with O_EXCL and renames it
    into place, so a symlink at the destination is replaced, not written
    through.
  """

  @max_links 40

  @spec resolve(Path.t(), Path.t()) ::
          {:ok, Path.t()}
          | {:error, :escapes_root | :too_many_links | :enoent | :enotdir | atom()}
  def resolve(root, rel) do
    root = Path.expand(root)

    if Path.type(rel) == :absolute do
      {:error, :escapes_root}
    else
      walk(root, root, Path.split(rel), 0)
    end
  end

  defp walk(_root, _cur, _parts, hops) when hops > @max_links, do: {:error, :too_many_links}
  defp walk(_root, cur, [], _hops), do: {:ok, cur}
  defp walk(root, cur, ["." | rest], hops), do: walk(root, cur, rest, hops)

  defp walk(root, cur, [".." | rest], hops) do
    parent = Path.dirname(cur)
    if inside?(parent, root), do: walk(root, parent, rest, hops), else: {:error, :escapes_root}
  end

  defp walk(root, cur, [part | rest], hops) do
    candidate = Path.join(cur, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, target} = :file.read_link_all(candidate)
        follow(root, cur, IO.chardata_to_string(target), rest, hops + 1)

      {:ok, %File.Stat{type: :directory}} ->
        walk(root, candidate, rest, hops)

      {:ok, %File.Stat{}} when rest == [] ->
        {:ok, candidate}

      {:ok, %File.Stat{}} ->
        {:error, :enotdir}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp follow(root, cur, target, rest, hops) do
    if Path.type(target) == :absolute do
      target = Path.expand(target)

      if inside?(target, root) do
        relative = Path.relative_to(target, root)
        parts = if relative == target or relative == ".", do: [], else: Path.split(relative)
        walk(root, root, parts ++ rest, hops)
      else
        {:error, :escapes_root}
      end
    else
      walk(root, cur, Path.split(target) ++ rest, hops)
    end
  end

  @doc """
  The path an absolute `path` really names, with every symlink along it
  followed (anywhere on the box, unlike `resolve/2`). A part that doesn't
  exist ends the walk, and the rest is kept as written.
  """
  @spec real_path(Path.t()) :: {:ok, Path.t()} | {:error, :too_many_links}
  def real_path(path) do
    ["/" | parts] = path |> Path.expand() |> Path.split()
    real_walk("/", parts, 0)
  end

  defp real_walk(_cur, _parts, hops) when hops > @max_links, do: {:error, :too_many_links}
  defp real_walk(cur, [], _hops), do: {:ok, cur}
  defp real_walk(cur, ["." | rest], hops), do: real_walk(cur, rest, hops)
  defp real_walk(cur, [".." | rest], hops), do: real_walk(Path.dirname(cur), rest, hops)

  defp real_walk(cur, [part | rest], hops) do
    candidate = Path.join(cur, part)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, target} = :file.read_link_all(candidate)
        target = IO.chardata_to_string(target)

        if Path.type(target) == :absolute do
          ["/" | parts] = Path.split(target)
          real_walk("/", parts ++ rest, hops + 1)
        else
          real_walk(cur, Path.split(target) ++ rest, hops + 1)
        end

      {:ok, _} ->
        real_walk(candidate, rest, hops)

      {:error, _} ->
        {:ok, Path.expand(Path.join([candidate | rest]))}
    end
  end

  @doc "True when `path` is `root` or below it (both already expanded)."
  def inside?(_path, "/"), do: true
  def inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  @spec read(Path.t(), Path.t(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def read(root, rel, opts) do
    max = Keyword.fetch!(opts, :max_bytes)

    with {:ok, path} <- resolve(root, rel),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(io, max + 1) do
          data when is_binary(data) and byte_size(data) > max -> {:error, :too_large}
          data when is_binary(data) -> {:ok, data}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, reason}
        end
      after
        File.close(io)
      end
    else
      {:ok, %File.Stat{}} -> {:error, :not_regular}
      error -> error
    end
  end

  @spec ensure_dir(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, atom()}
  def ensure_dir(root, rel) do
    root = Path.expand(root)
    parts = Path.split(rel)

    if Enum.any?(parts, &(&1 in [".", ".."])) or Path.type(rel) == :absolute do
      {:error, :escapes_root}
    else
      {parents, [last]} = Enum.split(parts, -1)

      with {:ok, parent} <- ensure_parents(root, parents) do
        replace_with_dir(Path.join(parent, last))
      end
    end
  end

  defp ensure_parents(root, parts) do
    Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, cur} ->
      path = Path.join(cur, part)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, path}}
        {:ok, %File.Stat{type: :symlink}} -> follow_parent(root, path)
        {:ok, %File.Stat{}} -> {:halt, {:error, :enotdir}}
        {:error, :enoent} -> mkdir(path)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A symlinked parent is fine when it resolves to a directory under the
  # root (a monorepo's .devcontainer pointing into tools/, say).
  defp follow_parent(root, path) do
    with {:ok, target} <- resolve(root, Path.relative_to(path, root)),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(target) do
      {:cont, {:ok, target}}
    else
      _ -> {:halt, {:error, :symlink_in_path}}
    end
  end

  defp mkdir(path) do
    case File.mkdir(path) do
      :ok -> {:cont, {:ok, path}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp replace_with_dir(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, path}

      {:ok, %File.Stat{}} ->
        # A symlink or a file: remove the entry itself, never its target.
        with :ok <- File.rm(path), :ok <- File.mkdir(path), do: {:ok, path}

      {:error, :enoent} ->
        with :ok <- File.mkdir(path), do: {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  @doc "Appends `line` to a file under `root` unless it's already there."
  @spec append_line(Path.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def append_line(root, rel, line) do
    root = Path.expand(root)
    {parents, [name]} = rel |> Path.split() |> Enum.split(-1)

    with {:ok, dir} <- existing_dir(root, parents) do
      path = Path.join(dir, name)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} -> append_if_missing(path, File.read!(path), line)
        {:ok, %File.Stat{}} -> {:error, :not_regular}
        {:error, :enoent} -> write_atomic(path, [line, "\n"], 0o644)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp append_if_missing(path, existing, line) do
    cond do
      line in String.split(existing, "\n") ->
        :ok

      existing == "" or String.ends_with?(existing, "\n") ->
        write_atomic(path, [existing, line, "\n"], 0o644)

      true ->
        write_atomic(path, [existing, "\n", line, "\n"], 0o644)
    end
  end

  defp existing_dir(root, parts) do
    Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, cur} ->
      path = Path.join(cur, part)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, path}}
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink_in_path}}
        {:ok, _} -> {:halt, {:error, :enotdir}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp random, do: 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
