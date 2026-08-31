# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :ptc_manager,
  operational_mode: :active,
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
  agent_action_adapter: PtcManager.MaintainerActions.CodexAdapter,
  agent_actions_enabled: false,
  agent_action_interval_ms: 5_000,
  agent_action_timeout_ms: 1_800_000,
  agent_action_sync_retry_base_ms: 5_000,
  agent_action_sync_retry_max_ms: 300_000,
  agent_action_run_as_user: nil,
  agent_action_output_dir: nil,
  planning_snapshot_root: nil,
  planning_git_binary: "/usr/bin/git",
  planning_snapshot_permission_check: false,
  daily_digest_enabled: false,
  daily_digest_interval_ms: 60_000,
  daily_digest_hour: 2,
  daily_digest_time_zone: "Europe/Stockholm",
  external_pr_run_as_user: nil,
  external_pr_group: nil,
  external_pr_worktree_root: nil,
  external_pr_push_run_as_user: nil,
  external_pr_push_wrapper: "/usr/local/bin/ptc-manager-external-push",
  external_pr_cleanup_wrapper: "/usr/local/bin/ptc-manager-external-cleanup",
  external_pr_git_wrapper: "/usr/local/bin/ptc-manager-external-git",
  external_pr_reconcile_enabled: false,
  dispatch_adapter: PtcManager.Dispatch.HerdrAdapter,
  dispatch_enabled: false,
  dispatch_interval_ms: 5_000,
  dispatch_lease_ms: 1_800_000,
  dispatch_reconcile_after_ms: 60_000,
  implementation_agent_capacity: 1,
  worktree_root: nil,
  worktree_permission_check: true,
  worktree_reconcile_interval_ms: 30_000,
  result_probe: PtcManager.Repository.GitProbe,
  result_reconcile_interval_ms: 0,
  result_claim_timeout_ms: 180_000,
  pull_request_client: PtcManager.GitHub.PullRequestClient,
  pr_reconcile_enabled: false,
  publish_broker: PtcManager.GitHub.AppBroker,
  publication_enabled: false,
  publication_interval_ms: 5_000,
  publication_claim_timeout_ms: 180_000,
  publication_max_attempts: 5,
  publication_retry_base_ms: 5_000,
  publication_retry_max_ms: 300_000,
  github_app_id: nil,
  github_app_installation_id: nil,
  github_app_private_key_path: nil,
  github_broker_home: nil,
  github_publish_staging_root: nil,
  github_publish_staging_stale_ms: 3_600_000,
  github_publish_bundle_max_bytes: 250_000_000,
  github_push_timeout_binary: nil,
  github_push_timeout_ms: 60_000,
  publication_status_interval_ms: 60_000,
  git_binary: "git",
  git_run_as_user: nil,
  git_verifier_home: nil,
  git_timeout_ms: 15_000,
  git_timeout_binary: nil,
  external_pr_command_timeout_ms: 180_000,
  git_diff_max_bytes: 50_000_000,
  git_max_commits: 100,
  git_max_changed_paths: 100,
  git_max_blob_bytes: 10_000_000,
  git_max_total_blob_bytes: 50_000_000,
  git_memory_limit_binary: nil,
  git_memory_limit_bytes: 268_435_456,
  implementation_agent_kind: "codex",
  implementation_agent_args: ["--dangerously-bypass-approvals-and-sandbox"],
  implementation_agent_start_timeout_ms: 60_000,
  implementation_agent_publishes_pr: false,
  required_pre_pr_reviews_default: 2,
  implementation_test_command: nil

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
