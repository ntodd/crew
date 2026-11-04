# The agent tarballs' store (CREW_AGENT_STORE_DIR) starts empty.
File.rm_rf!(Application.fetch_env!(:crew, :agent_store_dir))
ExUnit.start(capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Crew.Repo, :manual)
