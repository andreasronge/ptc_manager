# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ptc_manager,
  ecto_repos: [PtcManager.Repo],
  generators: [timestamp_type: :utc_datetime],
  github_client: PtcManager.GitHub.Client,
  repository_path: nil,
  github_sync_interval_ms: 0,
  herdr_client: PtcManager.Herdr.Client,
  herdr_run_as_user: nil,
  herdr_sync_interval_ms: 0,
  manager_adapter: PtcManager.Manager.CodexAdapter,
  manager_concurrency: 1,
  manager_output_dir: nil,
  manager_enabled: false,
  dispatch_adapter: PtcManager.Dispatch.HerdrAdapter,
  dispatch_enabled: false,
  dispatch_interval_ms: 5_000,
  dispatch_lease_ms: 1_800_000,
  dispatch_reconcile_after_ms: 60_000,
  dispatch_concurrency: 1,
  implementation_agent_kind: "codex",
  implementation_agent_args: ["--full-auto"],
  implementation_agent_start_timeout_ms: 60_000

# Configures the endpoint
config :ptc_manager, PtcManagerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PtcManagerWeb.ErrorHTML, json: PtcManagerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PtcManager.PubSub,
  live_view: [signing_salt: "wLAlQEB/"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ptc_manager: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  ptc_manager: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
