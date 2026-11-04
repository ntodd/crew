defmodule CrewImage.SmokeTest do
  @moduledoc "The smoke boot's pieces that don't need a VM: the fake JIT config and guest API."
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias CrewImage.Smoke.{FakeJIT, GuestAPI}

  defp decode!(b64), do: b64 |> Base.decode64!() |> Jason.decode!()

  describe "FakeJIT" do
    test "is GitHub's shape: base64 JSON of base64 settings files, with updates off" do
      jit = FakeJIT.build(name: "crew-smoke")
      files = decode!(jit)

      assert Map.keys(files) |> Enum.sort() == [
               ".credentials",
               ".credentials_rsaparams",
               ".runner"
             ]

      runner = decode!(files[".runner"])
      assert runner["DisableUpdate"] === true
      assert runner["AgentName"] == "crew-smoke"
      assert runner["Ephemeral"] === true

      creds = decode!(files[".credentials"])
      assert creds["Scheme"] == "OAuth"

      rsa = decode!(files[".credentials_rsaparams"])

      for k <- ~w(d dp dq exponent inverseQ modulus p q),
          do: assert({:ok, _} = Base.decode64(rsa[k]))
    end

    test "fits vm.start's jit_config limit (16 KiB)" do
      assert byte_size(FakeJIT.build(name: "crew-smoke")) < 16_384
    end
  end

  describe "GuestAPI" do
    setup do
      api =
        start_supervised!(
          {GuestAPI, token: "tok", payload: %{"jit_config" => "j"}, control_hold_ms: 50}
        )

      %{api: api}
    end

    defp call(api, method, path, body \\ "", token \\ "tok") do
      conn(method, path, body)
      |> put_req_header("authorization", "Bearer " <> token)
      |> GuestAPI.Plug.call(GuestAPI.Plug.init(api))
    end

    test "refuses a wrong token", %{api: api} do
      assert call(api, :get, "/v1/payload", "", "nope").status == 401
      assert GuestAPI.events(api) == []
    end

    test "serves the payload once, then 410", %{api: api} do
      conn = call(api, :get, "/v1/payload")
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"jit_config" => "j"}
      assert call(api, :get, "/v1/payload").status == 410
      assert [%{kind: :payload}, %{kind: :payload_refetch}] = GuestAPI.events(api)
    end

    test "records states, log lines and steps through CrewProtocol.Guest", %{api: api} do
      state = Jason.encode!(%{state: "job_finished", at: 1, detail: "exit_code=1"})
      assert call(api, :post, "/v1/state", state).status == 204

      log = Jason.encode!(%{t: 1, step_ref: nil, text: "hello"}) <> "\n"
      assert call(api, :post, "/v1/log", log).status == 204
      assert call(api, :post, "/v1/steps", ~s({"steps": []})).status == 204
      assert call(api, :post, "/v1/metrics", ~s({"cpu_pct": 3})).status == 204

      assert [
               %{kind: :state, data: %{state: "job_finished", detail: "exit_code=1"}},
               %{kind: :log, data: [%{text: "hello"}]},
               %{kind: :steps},
               %{kind: :metrics}
             ] = GuestAPI.events(api)
    end

    test "holds the control poll, and answers stop once asked", %{api: api} do
      assert call(api, :get, "/v1/control").status == 204

      task = Task.async(fn -> call(api, :get, "/v1/control") end)
      Process.sleep(10)
      GuestAPI.request_stop(api)
      conn = Task.await(task)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"stop" => true}
    end

    test "withholds the payload when told to (503, so crew-guest keeps asking)" do
      api = start_supervised!({GuestAPI, token: "tok", payload: :withhold}, id: :withhold)
      assert call(api, :get, "/v1/payload").status == 503
    end
  end
end
