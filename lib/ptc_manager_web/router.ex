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

  scope "/", PtcManagerWeb do
    pipe_through :browser

    get "/login", AuthController, :new
    post "/login", AuthController, :create
  end

  scope "/", PtcManagerWeb do
    pipe_through [:browser, :require_authenticated]

    live "/", DashboardLive, :index
    live "/board", DeliveryBoardLive, :index
    live "/operations", OperationsLive, :index
    live "/configuration", ConfigurationLive, :index
    delete "/logout", AuthController, :delete
  end

  defp require_authenticated(conn, opts),
    do: PtcManagerWeb.Auth.require_authenticated(conn, opts)

  # Other scopes may use custom stacks.
  # scope "/api", PtcManagerWeb do
  #   pipe_through :api
  # end
end
