defmodule CrewAgent.Driver.Firecracker.ConsoleTest do
  @moduledoc "The console cap (§11.3): the first 4 MiB, a marker and a rolling last 4 MiB."
  use ExUnit.Case, async: true

  alias CrewAgent.Driver.Firecracker.Console

  @moduletag :tmp_dir

  defp marker_len, do: byte_size(Console.marker(0))

  test "a console under the cap is left alone", %{tmp_dir: dir} do
    path = Path.join(dir, "console.log")
    File.write!(path, "boot\n")
    assert Console.cap(path, 100, 200) == :ok
    assert File.read!(path) == "boot\n"
    assert Console.cap(Path.join(dir, "missing.log"), 100, 200) == :ok
  end

  test "past the cap it keeps the head, a marker and the tail", %{tmp_dir: dir} do
    path = Path.join(dir, "console.log")
    head = :binary.copy("h", 100)
    body = head <> :binary.copy("m", 1000) <> "the very end"
    File.write!(path, body)

    assert Console.cap(path, 100, 200) ==
             {:truncated, byte_size(body) - 100 - (200 - marker_len())}

    out = File.read!(path)
    assert byte_size(out) == 300
    assert binary_part(out, 0, 100) == head
    assert binary_part(out, 100, marker_len()) =~ "[crew: console truncated"
    assert String.ends_with?(out, "the very end")
    keep = 200 - marker_len()
    assert binary_part(out, 300 - keep, keep) == binary_part(body, byte_size(body) - keep, keep)
  end

  test "the tail rolls on, and the marker counts everything dropped", %{tmp_dir: dir} do
    path = Path.join(dir, "console.log")
    File.write!(path, :binary.copy("h", 100) <> :binary.copy("a", 1000))
    {:truncated, first} = Console.cap(path, 100, 200)

    # More output, appended as systemd does (O_APPEND).
    File.write!(path, :binary.copy("b", 500) <> "newest", [:append])
    {:truncated, total} = Console.cap(path, 100, 200)
    out = File.read!(path)
    assert byte_size(out) == 300
    assert total == first + 506
    assert binary_part(out, 100, marker_len()) == Console.marker(total)
    assert String.ends_with?(out, "newest")
    refute out |> binary_part(100 + marker_len(), 200 - marker_len()) |> String.contains?("a")
  end

  test "the defaults are 4 MiB and 4 MiB", %{tmp_dir: dir} do
    path = Path.join(dir, "console.log")
    File.write!(path, :binary.copy("z", 9 * 1024 * 1024))
    assert {:truncated, _} = Console.cap(path)
    assert File.stat!(path).size == 8 * 1024 * 1024
  end

  test "it never follows a symlink", %{tmp_dir: dir} do
    target = Path.join(dir, "elsewhere")
    File.write!(target, :binary.copy("t", 1000))
    path = Path.join(dir, "console.log")
    File.ln_s!(target, path)
    assert Console.cap(path, 100, 200) == :ok
    assert File.stat!(target).size == 1000
  end
end
