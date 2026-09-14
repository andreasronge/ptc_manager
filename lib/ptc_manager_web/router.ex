defmodule PtcManagerWeb.Router do
  use PtcManagerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PtcManagerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Authentication runs before content negotiation so an unconfigured console
  # answers 404 to every request, whatever it accepts.
  pipeline :operator_api do
    plug PtcManagerWeb.OperatorAuth
    plug :accepts, ["json"]
  end

  scope "/", PtcManagerWeb do
    pipe_through :browser

    get "/login", AuthController, :new
    post "/login", AuthController, :create
  end

  scope "/", PtcManagerWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api/operator", PtcManagerWeb do
    pipe_through :operator_api

    get "/state", OperatorController, :state
    get "/stalls", OperatorController, :stalls
  end

  scope "/", PtcManagerWeb do
    pipe_through [:browser, :require_authenticated]

    live_session :maintainer,
      on_mount: [{PtcManagerWeb.MaintenanceMode, :default}] do
      live "/", DashboardLive, :index
      live "/board", DeliveryBoardLive, :index
      live "/updates", DailyDigestLive, :index
      live "/updates/:id", DailyDigestLive, :show
      live "/operations", OperationsLive, :index
      live "/operations/agents", OperationsLive, :agents
      live "/operations/performance", OperationsLive, :performance
      live "/automations", AutomationsLive, :index
      live "/automations/new", AutomationsLive, :new
      live "/automations/:id", AutomationsLive, :show
      live "/deployments", DeploymentsLive, :index
      live "/configuration", ConfigurationLive, :index
      live "/execution-profiles", ExecutionProfilesLive, :index
      live "/jobs/:id/reviews", JobReviewsLive, :show
      live "/jobs/:id/report", DeliveryReportLive, :show
    end

    delete "/logout", AuthController, :delete
  end

  defp require_authenticated(conn, opts),
    do: PtcManagerWeb.Auth.require_authenticated(conn, opts)
end
