defmodule Crew.GitHubStub do
  @moduledoc """
  Stubs GitHub's HTTP API with `Req.Test`, by method and path.

      GitHubStub.stub(%{
        {"GET", "/user"} => {200, %{"id" => 1, "login" => "mona"}},
        {"POST", "/login/oauth/access_token"} => fn conn -> ... end
      })

  A path may end in `*` to match a prefix. Anything not listed answers
  404, naming the request, so a missing stub is easy to spot.
  """
  import Plug.Conn

  def stub(routes) do
    Req.Test.stub(Crew.GitHub, fn conn ->
      case Enum.find(routes, fn {{method, path}, _} ->
             method == conn.method and path_matches?(path, conn.request_path)
           end) do
        {_, fun} when is_function(fun, 1) -> fun.(conn)
        {_, {status, body}} -> json(conn, status, body)
        nil -> json(conn, 404, %{"message" => "no stub for #{conn.method} #{conn.request_path}"})
      end
    end)
  end

  defp path_matches?(pattern, path) do
    if String.ends_with?(pattern, "*"),
      do: String.starts_with?(path, String.trim_trailing(pattern, "*")),
      else: pattern == path
  end

  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc "Reads a stubbed request's form or JSON body."
  def body(conn) do
    {:ok, raw, _} = read_body(conn)

    case get_req_header(conn, "content-type") do
      ["application/x-www-form-urlencoded" <> _] -> URI.decode_query(raw)
      _ -> if raw == "", do: %{}, else: Jason.decode!(raw)
    end
  end
end
