defmodule CrewWeb.Router do
  use CrewWeb, :router

  import CrewWeb.UserAuth
  import Oban.Web.Router

  # sobelow_skip ["Config.CSP"]
  # The policy is set by CrewWeb.Plugs.SecurityHeaders, per request.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CrewWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug CrewWeb.Plugs.SecurityHeaders
    plug :fetch_current_scope
  end

  pipeline :signed_in do
    plug :require_user
  end

  pipeline :admin do
    plug :require_user
    plug :require_admin
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health checks: no session, no pipeline, and not logged (they come
  # every few seconds).
  scope "/", CrewWeb do
    get "/healthz", HealthController, :show, log: false
  end

  # Signed-out pages: sign in, and first-run setup.
  scope "/", CrewWeb do
    pipe_through :browser

    get "/sign-in", AuthController, :new
    get "/auth/github", AuthController, :request
    get "/auth/github/callback", AuthController, :callback
    delete "/sign-out", AuthController, :delete

    get "/setup", SetupController, :show
    post "/setup", SetupController, :verify
    post "/setup/github", SetupController, :github
    get "/setup/github/callback", SetupController, :callback
    get "/setup/github/installed", SetupController, :installed
  end

  # Agents enroll with a join token. Everything after that is the signed
  # socket.
  scope "/", CrewWeb do
    pipe_through :api

    post "/api/agents/enroll", AgentController, :enroll
  end

  # Guest image files, for boxes' `image.prepare` (§13.1). Signed, and
  # checked by the agent; no pipeline, since they're large and binary.
  scope "/", CrewWeb do
    get "/images/:id/:file", ImageController, :show
  end

  # What boxes fetch before they have an identity (§12.2, §12.3, §20.1):
  # agent release tarballs (signed), and for Flatcar boxes the
  # launchers and the Ignition, which takes a join token. Not the api
  # pipeline: tarballs and scripts aren't JSON, and curl asks for */*.
  scope "/agent", CrewWeb do
    get "/releases/:version/:target/:file", AgentController, :release
    post "/flatcar/ignition", AgentController, :flatcar_ignition
    get "/linux-vm.sh", AgentController, :linux_vm_script
    get "/mac-vm.sh", AgentController, :mac_vm_script
  end

  # Admin pages outside /admin. Before the signed-in scope, so
  # /boxes/new isn't taken for a box id.
  scope "/", CrewWeb do
    pipe_through [:browser, :admin]

    get "/boxes/:id/reprovision.ign", BoxController, :reprovision

    live_session :admin_actions,
      on_mount: [
        {CrewWeb.StaleAssets, :reload},
        {CrewWeb.UserAuth, :require_user},
        {CrewWeb.UserAuth, :require_admin}
      ] do
      live "/boxes/new", BoxLive.New, :new
    end
  end

  scope "/", CrewWeb do
    pipe_through [:browser, :signed_in]

    get "/runs/:run_id/attempts/:n/jobs/:job_id/log.txt", JobLogController, :raw

    live_session :signed_in,
      on_mount: [{CrewWeb.StaleAssets, :reload}, {CrewWeb.UserAuth, :require_user}] do
      live "/", DashboardLive, :index
      live "/runs", RunLive.Index, :index
      live "/runs/:run_id/attempts/:n", RunLive.Show, :show
      live "/runs/:run_id/attempts/:n/jobs/:job_id", JobLive.Show, :show
      live "/queue", QueueLive, :index
      live "/repos", RepoLive.Index, :index
      live "/repos/:id", RepoLive.Show, :show
      live "/boxes", BoxLive.Index, :index
      live "/boxes/:id", BoxLive.Show, :show
    end
  end

  scope "/admin", CrewWeb do
    pipe_through [:browser, :admin]

    live_session :admin,
      on_mount: [
        {CrewWeb.StaleAssets, :reload},
        {CrewWeb.UserAuth, :require_user},
        {CrewWeb.UserAuth, :require_admin}
      ] do
      live "/", AdminLive.Deployment, :index
      live "/users", AdminLive.Users, :index
      live "/audit", AdminLive.Audit, :index
      live "/sizes", AdminLive.Sizes, :index
      live "/images", AdminLive.Images, :index
      live "/caches", AdminLive.Caches, :index
    end
  end

  scope "/admin" do
    pipe_through [:browser, :admin]

    oban_dashboard("/oban", resolver: CrewWeb.ObanResolver)
  end

  if Application.compile_env(:crew, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CrewWeb.Telemetry
      get "/sign-in/:login", CrewWeb.DevAuthController, :create
    end
  end
end
