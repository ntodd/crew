defmodule CrewAgent.Images.Download do
  @moduledoc """
  Streams a URL into a `.part` file, hashing as it goes, for
  `image.prepare` (§13.1).

  - **Capped:** a server that sends more than the expected size is
    refused, not retried.
  - **Retried:** connection errors, timeouts, 408, 429, 5xx and a body cut
    short are retried with backoff. Each retry resumes the part with
    `Range: bytes=<n>-`. A server that answers 200 instead starts it over.
  - **Resumed:** a part already on disk (left by a prepare that was
    killed) is hashed and continued the same way. The SHA-256 covers the
    whole file, so a bad part fails the check like a bad download.
  """

  alias CrewProtocol.Auth

  require Logger

  @read_chunk 1_048_576

  @doc """
  Downloads `url` to `path` until it holds `size` bytes, and returns
  their SHA-256 (lowercase hex). Options:

  - `:attempts` (5) and `:retry_delay_ms` (1000, doubled per retry, at
    most 30 s);
  - `:on_bytes`, called with the bytes in the part as they grow, and
    `:on_retry`, called before each retry;
  - `:sign`, given each request's URL (redirects included), returns the
    headers that authenticate it, or `[]`;
  - `:req_options`, merged into Req's.
  """
  @spec fetch(String.t(), Path.t(), non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def fetch(url, path, size, opts \\ []), do: fetch(url, path, size, opts, 1)

  defp fetch(url, path, size, opts, n) do
    attempts = Keyword.get(opts, :attempts, 5)

    case attempt(url, path, size, opts) do
      {:ok, sha} ->
        {:ok, sha}

      {:retry, reason} when n < attempts ->
        Logger.warning("downloading #{Path.basename(path)} failed (#{reason}); retrying")
        Keyword.get(opts, :on_retry, fn -> :ok end).()
        Process.sleep(min(Keyword.get(opts, :retry_delay_ms, 1000) * 2 ** (n - 1), 30_000))
        fetch(url, path, size, opts, n + 1)

      {:retry, reason} ->
        {:error, "#{reason} (#{attempts} attempts)"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attempt(url, path, size, opts) do
    case resume(path, size) do
      {:ok, ^size, hash} -> {:ok, hex(hash)}
      {:ok, offset, hash} -> request(url, path, size, offset, hash, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  # What the part already holds, hashed. One longer than the file can't
  # be right, so it's started over.
  defp resume(path, size) do
    case File.stat(path) do
      {:ok, %File.Stat{size: n}} when n <= size ->
        {:ok, n, path |> File.stream!(@read_chunk) |> Enum.reduce(init(), &hash(&2, &1))}

      {:ok, _} ->
        with :ok <- File.rm(path), do: {:ok, 0, init()}

      {:error, :enoent} ->
        {:ok, 0, init()}

      {:error, reason} ->
        {:error, "can't read #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp request(url, path, size, offset, hash, opts) do
    case :file.open(path, [:read, :write, :raw, :binary]) do
      {:ok, fd} ->
        try do
          {:ok, ^offset} = :file.position(fd, offset)
          start = %{fd: fd, size: size, offset: offset, hash: hash, write?: false, stop: nil}
          on_bytes = Keyword.get(opts, :on_bytes, fn _ -> :ok end)

          Req.new(
            url: url,
            headers: if(offset > 0, do: [{"range", "bytes=#{offset}-"}], else: []),
            into: &into(&1, &2, start, on_bytes),
            retry: false,
            receive_timeout: 30_000
          )
          |> Req.Request.append_request_steps(crew_sign: sign_step(Keyword.get(opts, :sign)))
          |> Req.merge(Keyword.get(opts, :req_options, []))
          |> Req.request()
          |> outcome(start)
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, "can't write #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  # Every request, redirects included, gets fresh headers for its own URL,
  # so a redirect elsewhere never carries the agent's.
  defp sign_step(nil), do: & &1

  defp sign_step(sign) do
    fn request ->
      request = Enum.reduce(Auth.header_names(), request, &Req.Request.delete_header(&2, &1))

      Enum.reduce(sign.(request.url), request, fn {k, v}, r -> Req.Request.put_header(r, k, v) end)
    end
  end

  defp into({:data, data}, {req, resp}, start, on_bytes) do
    st = Req.Response.get_private(resp, :download) || begin(start, resp)

    case write(st, data, on_bytes) do
      {:cont, st} -> {:cont, {req, Req.Response.put_private(resp, :download, st)}}
      {:halt, st} -> {:halt, {req, Req.Response.put_private(resp, :download, st)}}
    end
  end

  # The first chunk of a response decides what its body is: the rest of
  # the part (206 from our offset), all of it (200), or nothing to keep.
  defp begin(start, %Req.Response{status: 200}) do
    if start.offset > 0, do: truncate(start.fd)
    %{start | offset: 0, hash: init(), write?: true}
  end

  defp begin(start, %Req.Response{status: 206} = resp) do
    case Req.Response.get_header(resp, "content-range") do
      ["bytes " <> range] ->
        if String.starts_with?(range, "#{start.offset}-"),
          do: %{start | write?: true},
          else: start_over(start)

      _ ->
        start_over(start)
    end
  end

  defp begin(start, _resp), do: start

  defp start_over(start) do
    truncate(start.fd)
    %{start | stop: {:retry, "the server sent a range that wasn't asked for"}}
  end

  defp write(%{stop: stop} = st, _data, _on_bytes) when stop != nil, do: {:halt, st}
  defp write(%{write?: false} = st, _data, _on_bytes), do: {:cont, st}

  defp write(st, data, on_bytes) do
    offset = st.offset + byte_size(data)

    if offset > st.size do
      {:halt, %{st | stop: {:error, "the server sent more than the expected #{st.size} bytes"}}}
    else
      case :file.write(st.fd, data) do
        :ok ->
          on_bytes.(offset)
          {:cont, %{st | offset: offset, hash: hash(st.hash, data)}}

        {:error, reason} ->
          {:halt,
           %{st | stop: {:error, "writing the part failed: #{:file.format_error(reason)}"}}}
      end
    end
  end

  defp outcome({:ok, %Req.Response{status: status} = resp}, start) do
    case Req.Response.get_private(resp, :download) do
      %{stop: stop} when stop != nil ->
        stop

      %{size: size, offset: size, hash: hash, fd: fd} when status in [200, 206] ->
        :ok = :file.sync(fd)
        {:ok, hex(hash)}

      %{offset: offset} when status in [200, 206] ->
        {:retry, "the body stopped at #{offset} of #{start.size} bytes"}

      _ ->
        status_outcome(status, start)
    end
  end

  defp outcome({:error, exception}, _start), do: {:retry, Exception.message(exception)}

  defp status_outcome(status, _start) when status in [200, 206],
    do: {:retry, "an empty body"}

  # The part is longer than the server's file, or the file changed.
  defp status_outcome(416, start) do
    truncate(start.fd)
    {:retry, "HTTP 416"}
  end

  defp status_outcome(status, _start) when status in [408, 429] or status >= 500,
    do: {:retry, "HTTP #{status}"}

  defp status_outcome(status, _start), do: {:error, "HTTP #{status}"}

  defp truncate(fd) do
    {:ok, 0} = :file.position(fd, 0)
    :ok = :file.truncate(fd)
  end

  defp init, do: :crypto.hash_init(:sha256)
  defp hash(state, data), do: :crypto.hash_update(state, data)
  defp hex(state), do: state |> :crypto.hash_final() |> Base.encode16(case: :lower)
end
