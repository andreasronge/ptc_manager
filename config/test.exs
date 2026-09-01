import Config

config :ptc_manager, :admin_password, "test-password"

config :ptc_manager, Oban,
  engine: Oban.Engines.Lite,
  repo: PtcManager.Repo,
  testing: :manual,
  queues: false,
  plugins: false

config :ptc_manager,
  github_sync_interval_ms: 0,
  herdr_sync_interval_ms: 0,
  manager_enabled: false,
  agent_actions_enabled: false,
  dispatch_enabled: false,
  result_reconcile_interval_ms: 0,
  publication_enabled: false,
  pr_reconcile_enabled: false,
  implementation_agent_capacity: 1,
  worktree_root: System.tmp_dir!(),
  worktree_permission_check: false,
  worktree_reconcile_interval_ms: 0,
  checkout_probe: PtcManager.TestCheckoutProbe,
  publish_broker: PtcManager.GitHub.DisabledPublishBroker,
  github_publish_staging_root: System.tmp_dir!(),
  git_run_as_user: nil,
  git_verifier_home: System.tmp_dir!()

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ptc_manager, PtcManager.Repo,
  database: Path.expand("../ptc_manager_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ptc_manager, PtcManagerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3Q7Xpp8F1GiD5ab6AjUX/JpUrAE4sk+fdTVTH5eLr+wi7YvS5ppdTqPm24lYZMA0",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
