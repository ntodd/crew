defmodule Crew.Setup do
  @moduledoc """
  First-run setup. Until a GitHub App is configured nobody can sign in,
  so the setup pages are guarded by a one-time token that's printed to
  the log at boot (like a router's default password, but random and
  only valid until setup is done).
  """
  use GenServer

  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "True while the GitHub App isn't configured."
  def needed?, do: not Crew.GitHub.configured?()

  def verify(token) when is_binary(token) do
    case :persistent_term.get(__MODULE__, nil) do
      nil -> false
      expected -> Plug.Crypto.secure_compare(token, expected)
    end
  end

  def verify(_), do: false

  @doc """
  What every boot does: makes sure the deployment has its id (§3), which
  prefixes every runner name, however the App was configured.
  """
  def on_boot do
    Crew.Settings.ensure_deployment_id()
    :ok
  end

  @impl true
  def init(_) do
    unless Application.get_env(:crew, :env) == :test, do: on_boot()

    if needed?() do
      token =
        fixed_token() || 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      :persistent_term.put(__MODULE__, token)

      unless Application.get_env(:crew, :env) == :test do
        Logger.warning("""
        Crew isn't connected to GitHub yet. Finish setup at
            #{Crew.Config.base_url()}/setup
        with this one-time setup token:
            #{token}
        """)
      end
    end

    {:ok, nil}
  end

  # End-to-end runs drive setup through the browser, so in development
  # CREW_SETUP_TOKEN can fix the token. Releases always make a random one.
  defp fixed_token do
    with true <- Application.get_env(:crew, :dev_routes, false),
         token when is_binary(token) and byte_size(token) >= 16 <-
           System.get_env("CREW_SETUP_TOKEN") do
      token
    else
      _ -> nil
    end
  end
end
