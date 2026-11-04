defmodule CrewWeb.JobLogController do
  @moduledoc """
  **Download raw** (§17.6): a job's log as plain text, never sniffed,
  always an attachment, for those who can read its repo (§18.3).
  """
  use CrewWeb, :controller

  alias Crew.{Jobs, Logs}

  def raw(conn, %{"run_id" => run_id, "n" => n, "job_id" => job_id} = params) do
    with {run_id, ""} <- Integer.parse(run_id),
         {n, ""} <- Integer.parse(n),
         {job_id, ""} <- Integer.parse(job_id),
         {_attempt, job} <- find(conn.assigns.current_scope, run_id, n, job_id) do
      {kind, owner} = if params["source"] == "github", do: {:job, job.id}, else: {:vm, job.vm_id}
      lines = if owner, do: Logs.raw(kind, owner), else: []

      conn =
        conn
        |> put_resp_header("content-type", "text/plain; charset=utf-8")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename(job)}.log"))
        |> send_chunked(200)

      Enum.reduce_while(lines, conn, fn chunk, conn ->
        case chunk(conn, chunk) do
          {:ok, conn} -> {:cont, conn}
          {:error, _} -> {:halt, conn}
        end
      end)
    else
      _ -> conn |> put_status(404) |> text("Not found")
    end
  end

  defp find(scope, run_id, n, job_id) do
    Jobs.get_attempt_job!(scope, run_id, n, job_id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp filename(job), do: "job-#{job.github_id}"
end
