defmodule CrewGuest.JITTest do
  use ExUnit.Case, async: true

  import CrewGuest.TestHelpers

  alias CrewGuest.JIT

  test "a config whose runner settings disable updates is accepted" do
    assert :ok = JIT.check(jit_config(%{"DisableUpdate" => true}))
  end

  test "updates left on, or not mentioned, are refused" do
    assert {:error, :update_not_disabled} = JIT.check(jit_config(%{"DisableUpdate" => false}))
    assert {:error, :update_not_disabled} = JIT.check(jit_config(%{"DisableUpdate" => "true"}))

    runner = Base.encode64(Jason.encode!(%{"AgentId" => 1}))
    config = Base.encode64(Jason.encode!(%{".runner" => runner}))
    assert {:error, :update_not_disabled} = JIT.check(config)
  end

  test "padding and surrounding whitespace don't matter" do
    config = jit_config() |> String.trim_trailing("=")
    assert :ok = JIT.check(" " <> config <> "\n")
  end

  test "anything that doesn't decode is refused" do
    assert {:error, :bad_jit_config} = JIT.check("not base64!")
    assert {:error, :bad_jit_config} = JIT.check(Base.encode64("not json"))
    assert {:error, :bad_jit_config} = JIT.check(Base.encode64(~s(["a list"])))
    assert {:error, :bad_jit_config} = JIT.check(Base.encode64(~s({".runner": "%%%"})))
    assert {:error, :bad_jit_config} = JIT.check(Base.encode64(~s({"other": "x"})))
    assert {:error, :bad_jit_config} = JIT.check(nil)
  end
end
