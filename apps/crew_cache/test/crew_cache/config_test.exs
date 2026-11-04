defmodule CrewCache.ConfigTest do
  use ExUnit.Case, async: true

  alias CrewCache.Config

  @moduletag :tmp_dir

  test "needs a directory", %{tmp_dir: _} do
    assert {:error, message} = Config.new(dir: nil)
    assert message =~ "directory"
  end

  test "parent mode isn't built", %{tmp_dir: dir} do
    assert {:error, message} = Config.new(dir: dir, mode: :parent)
    assert message =~ "box mode"
  end

  test "management off loopback needs a token", %{tmp_dir: dir} do
    assert {:error, message} = Config.new(dir: dir, mgmt: {{100, 64, 0, 7}, 7780})
    assert message =~ "CREW_CACHE_MGMT_TOKEN"

    assert {:ok, _} = Config.new(dir: dir, mgmt: {{100, 64, 0, 7}, 7780}, mgmt_token: "t")
    assert {:ok, _} = Config.new(dir: dir, mgmt: {{127, 0, 0, 1}, 7780})
  end

  test "the quota defaults to a quarter of the disk", %{tmp_dir: dir} do
    {:ok, config} = Config.new(dir: dir)
    {out, 0} = System.cmd("df", ["-Pk", dir])
    [_, line | _] = String.split(out, "\n", trim: true)
    total = line |> String.split() |> Enum.at(1) |> String.to_integer()
    assert config.max_bytes == div(total * 1024, 4)

    assert {:ok, %{max_bytes: 5}} = Config.new(dir: dir, max_bytes: 5)
  end

  test "inspect hides the management token", %{tmp_dir: dir} do
    {:ok, config} = Config.new(dir: dir, mgmt_token: "mgmt-secret")
    refute inspect(config) =~ "mgmt-secret"
  end
end
