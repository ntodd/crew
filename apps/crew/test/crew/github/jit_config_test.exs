defmodule Crew.GitHub.JitConfigTest do
  use ExUnit.Case, async: true

  alias Crew.GitHub.JitConfig

  # GitHub's shape: base64 of a JSON object of base64'd settings files,
  # and its `.runner` leaves DisableUpdate out.
  defp encode(files) do
    files
    |> Map.new(fn {name, content} -> {name, Base.encode64(content)} end)
    |> Jason.encode!()
    |> Base.encode64()
  end

  defp files(jit) do
    jit
    |> Base.decode64!()
    |> Jason.decode!()
    |> Map.new(fn {name, content} -> {name, Base.decode64!(content)} end)
  end

  @runner ~s({"AgentId":42,"AgentName":"crew-x","PoolId":1,"PoolName":"Default","ServerUrl":"https://pipelines.example/","GitHubUrl":"https://github.com/o/r","WorkFolder":"_work","UseV2Flow":true})

  test "sets DisableUpdate in .runner and keeps the rest" do
    jit = encode(%{".runner" => @runner, ".credentials" => ~s({"Scheme":"OAuth"})})

    out = files(JitConfig.disable_update(jit))

    runner = Jason.decode!(out[".runner"])
    assert runner["DisableUpdate"] == true
    assert Map.delete(runner, "DisableUpdate") == Jason.decode!(@runner)
    assert out[".credentials"] == ~s({"Scheme":"OAuth"})
  end

  test "overrides a DisableUpdate of false" do
    jit = encode(%{".runner" => ~s({"AgentId":1,"DisableUpdate":false})})
    assert Jason.decode!(files(JitConfig.disable_update(jit))[".runner"])["DisableUpdate"] == true
  end

  test "passes anything it can't read through, for the guest to refuse" do
    for jit <- ["not base64!", Base.encode64("[]"), encode(%{".credentials" => "{}"})] do
      assert JitConfig.disable_update(jit) == jit
    end
  end
end
