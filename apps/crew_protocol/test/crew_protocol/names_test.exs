defmodule CrewProtocol.NamesTest do
  use ExUnit.Case, async: true

  alias CrewProtocol.Names

  test "box names are DNS labels of at most 40 characters" do
    assert Names.box_name?("m3max")
    assert Names.box_name?("linux-a")
    assert Names.box_name?(String.duplicate("a", 40))
    refute Names.box_name?(String.duplicate("a", 41))
    refute Names.box_name?("M3")
    refute Names.box_name?("-a")
    refute Names.box_name?("a-")
    refute Names.box_name?("")
    refute Names.box_name?(nil)
  end

  test "deployment ids are 4 characters of [a-z0-9]" do
    assert Names.deployment_id?("ab12")
    refute Names.deployment_id?("AB12")
    refute Names.deployment_id?("abc")
    refute Names.deployment_id?("abcde")

    for _ <- 1..50 do
      assert Names.deployment_id?(Names.new_deployment_id())
    end
  end

  test "the VM suffix is the last 10 hex characters of the VM's UUID" do
    assert Names.vm_suffix("0190f0a2-7b1c-7d2e-8f3a-1b2c3d4e5f60") == "2c3d4e5f60"
  end

  test "runner names are crew-<deployment>-<box>-<suffix>, at most 61 characters" do
    vm_id = "0190f0a2-7b1c-7d2e-8f3a-1b2c3d4e5f60"
    assert Names.runner_name("ab12", "m3max", vm_id) == "crew-ab12-m3max-2c3d4e5f60"

    long = Names.runner_name("ab12", String.duplicate("b", 40), vm_id)
    assert String.length(long) == 61
  end

  test "parse_runner_name/1 splits a runner name back up" do
    assert Names.parse_runner_name("crew-ab12-linux-a-2c3d4e5f60") ==
             {:ok, %{deployment_id: "ab12", box: "linux-a", suffix: "2c3d4e5f60"}}

    assert Names.parse_runner_name("ubuntu-24.04") == :error
    assert Names.parse_runner_name("crew-ab12-x-zz") == :error
    assert Names.parse_runner_name(nil) == :error
  end

  test "ours?/2 is whether a runner name belongs to this deployment" do
    assert Names.ours?("crew-ab12-m3max-2c3d4e5f60", "ab12")
    refute Names.ours?("crew-zz99-m3max-2c3d4e5f60", "ab12")
    refute Names.ours?("GitHub Actions 2", "ab12")
  end
end
