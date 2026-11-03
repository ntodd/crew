defmodule Crew.Repo do
  @database Application.compile_env(:crew, :database, "sqlite")

  use Ecto.Repo,
    otp_app: :crew,
    adapter: if(@database == "postgres", do: Ecto.Adapters.Postgres, else: Ecto.Adapters.SQLite3)

  @doc ~s|The database this build was compiled for: "sqlite" or "postgres".|
  def database, do: @database

  def sqlite?, do: @database == "sqlite"
end
