defmodule CrewWeb.Plugs.SecurityHeaders do
  @moduledoc """
  The browser security policy for every page.

  Scripts and styles come only from the app's own origin: no inline
  scripts, no inline style attributes. Forms may post to GitHub (the
  GitHub App manifest flow submits there). Nothing may frame Crew.
  Development relaxes scripts and styles for the live reloader and
  debug pages; Oban Web needs inline styles, so its pages get that one
  exception.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      conn
      |> put_resp_header("content-security-policy", policy(conn))
      |> put_resp_header("cross-origin-opener-policy", "same-origin")
      |> put_resp_header(
        "permissions-policy",
        "camera=(), microphone=(), geolocation=(), payment=()"
      )
      |> put_resp_header("x-frame-options", "DENY")
      |> maybe_hsts()
    end)
  end

  defp policy(conn) do
    dev? = Application.get_env(:crew, :dev_routes, false)
    oban? = String.starts_with?(conn.request_path, "/admin/oban")

    script = if dev?, do: "'self' 'unsafe-inline'", else: "'self'"
    style = if dev? or oban?, do: "'self' 'unsafe-inline'", else: "'self'"

    Enum.join(
      [
        "default-src 'self'",
        "script-src #{script}",
        "style-src #{style}",
        "img-src 'self' data: https://avatars.githubusercontent.com",
        "font-src 'self'",
        "connect-src 'self'",
        "form-action 'self' #{Crew.GitHub.Client.web_url()}",
        "frame-ancestors 'none'",
        "base-uri 'self'",
        "object-src 'none'"
      ],
      "; "
    )
  end

  defp maybe_hsts(conn) do
    if conn.scheme == :https or get_req_header(conn, "x-forwarded-proto") == ["https"],
      do: put_resp_header(conn, "strict-transport-security", "max-age=31536000"),
      else: conn
  end
end
