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

  scope "/", CrewWeb do
    pipe_through [:browser, :signed_in]

    live_session :signed_in,
      on_mount: [{CrewWeb.StaleAssets, :reload}, {CrewWeb.UserAuth, :require_user}] do
      live "/", DashboardLive, :index
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
