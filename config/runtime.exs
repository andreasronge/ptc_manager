import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ptc_manager start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ptc_manager, PtcManagerWeb.Endpoint, server: true
end

github_sync_interval_ms =
  System.get_env("PTC_GITHUB_SYNC_INTERVAL_MS", "0") |> String.to_integer()

herdr_sync_interval_ms =
  System.get_env("PTC_HERDR_SYNC_INTERVAL_MS", "0") |> String.to_integer()

herdr_run_as_user = System.get_env("PTC_HERDR_RUN_AS_USER")

herdr_git_binary =
  System.get_env("PTC_HERDR_GIT_BINARY") ||
    if herdr_run_as_user in [nil, ""] do
      System.get_env("PTC_GIT_BINARY", "git")
    else
      "/usr/local/bin/ptc-manager-worker-git"
    end

dispatch_enabled = System.get_env("PTC_DISPATCH_ENABLED") == "true"
agent_actions_enabled = System.get_env("PTC_AGENT_ACTIONS_ENABLED") == "true"

publication_enabled = System.get_env("PTC_PUBLICATION_ENABLED") == "true"

implementation_agent_publishes_pr =
  System.get_env("PTC_IMPLEMENTATION_AGENT_PUBLISHES_PR", "false") == "true"

pr_reconcile_enabled =
  case System.get_env("PTC_PR_RECONCILE_ENABLED") do
    nil -> implementation_agent_publishes_pr or github_sync_interval_ms > 0
    "true" -> true
    "false" -> false
    _value -> raise "PTC_PR_RECONCILE_ENABLED must be true or false when set"
  end

external_pr_reconcile_enabled = pr_reconcile_enabled

config :ptc_manager,
  github_read_token: System.get_env("GITHUB_READ_TOKEN"),
  repository_path: System.get_env("PTC_REPOSITORY_PATH"),
  github_sync_interval_ms: github_sync_interval_ms,
  herdr_sync_interval_ms: herdr_sync_interval_ms,
  herdr_session: System.get_env("PTC_HERDR_SESSION", "default"),
  herdr_binary: System.get_env("PTC_HERDR_BINARY", "herdr"),
  herdr_run_as_user: herdr_run_as_user,
  herdr_git_binary: herdr_git_binary,
  herdr_socket_path: System.get_env("PTC_HERDR_SOCKET_PATH"),
  herdr_timeout_ms: System.get_env("PTC_HERDR_TIMEOUT_MS", "15000") |> String.to_integer(),
  herdr_stale_after_ms:
    System.get_env("PTC_HERDR_STALE_AFTER_MS", "60000") |> String.to_integer(),
  dispatch_enabled: dispatch_enabled,
  agent_actions_enabled: agent_actions_enabled,
  agent_action_interval_ms:
    System.get_env("PTC_AGENT_ACTION_INTERVAL_MS", "5000") |> String.to_integer(),
  agent_action_timeout_ms:
    System.get_env("PTC_AGENT_ACTION_TIMEOUT_MS", "7200000") |> String.to_integer(),
  agent_action_sync_retry_base_ms:
    System.get_env("PTC_AGENT_ACTION_SYNC_RETRY_BASE_MS", "5000") |> String.to_integer(),
  agent_action_sync_retry_max_ms:
    System.get_env("PTC_AGENT_ACTION_SYNC_RETRY_MAX_MS", "300000") |> String.to_integer(),
  agent_action_run_as_user: System.get_env("PTC_AGENT_ACTION_RUN_AS_USER"),
  planning_snapshot_root:
    System.get_env("PTC_PLANNING_SNAPSHOT_ROOT") ||
      if(System.get_env("RELEASE_NAME"),
        do: "/var/lib/ptc_manager-output/planning-snapshots"
      ),
  planning_git_binary: System.get_env("PTC_PLANNING_GIT_BINARY", "/usr/bin/git"),
  planning_snapshot_permission_check:
    System.get_env(
      "PTC_PLANNING_SNAPSHOT_PERMISSION_CHECK",
      if(System.get_env("RELEASE_NAME"), do: "true", else: "false")
    ) == "true",
  external_pr_run_as_user: System.get_env("PTC_EXTERNAL_PR_RUN_AS_USER", "ptc-manager-external"),
  external_pr_group: System.get_env("PTC_EXTERNAL_PR_GROUP", "ptc-manager-external"),
  external_pr_worktree_root:
    System.get_env("PTC_EXTERNAL_PR_WORKTREE_ROOT", "/srv/ptc_manager-external"),
  external_pr_push_run_as_user:
    System.get_env("PTC_EXTERNAL_PR_PUSH_RUN_AS_USER") ||
      System.get_env("PTC_AGENT_ACTION_RUN_AS_USER"),
  external_pr_push_wrapper:
    System.get_env("PTC_EXTERNAL_PR_PUSH_WRAPPER", "/usr/local/bin/ptc-manager-external-push"),
  external_pr_cleanup_wrapper:
    System.get_env(
      "PTC_EXTERNAL_PR_CLEANUP_WRAPPER",
      "/usr/local/bin/ptc-manager-external-cleanup"
    ),
  external_pr_git_wrapper:
    System.get_env("PTC_EXTERNAL_PR_GIT_WRAPPER", "/usr/local/bin/ptc-manager-external-git"),
  external_pr_reconcile_enabled: external_pr_reconcile_enabled,
  agent_action_output_dir: System.get_env("PTC_AGENT_ACTION_OUTPUT_DIR"),
  dispatch_interval_ms: System.get_env("PTC_DISPATCH_INTERVAL_MS", "5000") |> String.to_integer(),
  dispatch_lease_ms: System.get_env("PTC_DISPATCH_LEASE_MS", "1800000") |> String.to_integer(),
  dispatch_reconcile_after_ms:
    System.get_env("PTC_DISPATCH_RECONCILE_AFTER_MS", "60000") |> String.to_integer(),
  implementation_agent_capacity:
    System.get_env("PTC_IMPLEMENTATION_AGENT_CAPACITY", "1") |> String.to_integer(),
  worktree_reconcile_interval_ms:
    System.get_env("PTC_WORKTREE_RECONCILE_INTERVAL_MS", "30000") |> String.to_integer(),
  result_reconcile_interval_ms:
    System.get_env("PTC_RESULT_RECONCILE_INTERVAL_MS", "0") |> String.to_integer(),
  result_claim_timeout_ms:
    System.get_env("PTC_RESULT_CLAIM_TIMEOUT_MS", "180000") |> String.to_integer(),
  pr_reconcile_enabled: pr_reconcile_enabled,
  publication_enabled: publication_enabled,
  publication_interval_ms:
    System.get_env("PTC_PUBLICATION_INTERVAL_MS", "5000") |> String.to_integer(),
  publication_claim_timeout_ms:
    System.get_env("PTC_PUBLICATION_CLAIM_TIMEOUT_MS", "180000") |> String.to_integer(),
  publication_max_attempts:
    System.get_env("PTC_PUBLICATION_MAX_ATTEMPTS", "5") |> String.to_integer(),
  publication_retry_base_ms:
    System.get_env("PTC_PUBLICATION_RETRY_BASE_MS", "5000") |> String.to_integer(),
  publication_retry_max_ms:
    System.get_env("PTC_PUBLICATION_RETRY_MAX_MS", "300000") |> String.to_integer(),
  github_app_id: System.get_env("PTC_GITHUB_APP_ID"),
  github_app_installation_id: System.get_env("PTC_GITHUB_APP_INSTALLATION_ID"),
  github_app_private_key_path: System.get_env("PTC_GITHUB_APP_PRIVATE_KEY_PATH"),
  github_broker_home: System.get_env("PTC_GITHUB_BROKER_HOME"),
  github_publish_staging_root: System.get_env("PTC_GITHUB_PUBLISH_STAGING_ROOT"),
  github_publish_staging_stale_ms:
    System.get_env("PTC_GITHUB_PUBLISH_STAGING_STALE_MS", "3600000") |> String.to_integer(),
  github_publish_bundle_max_bytes:
    System.get_env("PTC_GITHUB_PUBLISH_BUNDLE_MAX_BYTES", "250000000") |> String.to_integer(),
  github_push_timeout_binary: System.get_env("PTC_GITHUB_PUSH_TIMEOUT_BINARY"),
  github_push_timeout_ms:
    System.get_env("PTC_GITHUB_PUSH_TIMEOUT_MS", "60000") |> String.to_integer(),
  publication_status_interval_ms:
    (System.get_env("PTC_PR_STATUS_INTERVAL_MS") ||
       System.get_env("PTC_PUBLICATION_STATUS_INTERVAL_MS", "60000"))
    |> String.to_integer(),
  git_binary: System.get_env("PTC_GIT_BINARY", "git"),
  git_run_as_user: System.get_env("PTC_GIT_RUN_AS_USER"),
  git_verifier_home: System.get_env("PTC_GIT_VERIFIER_HOME"),
  git_timeout_ms: System.get_env("PTC_GIT_TIMEOUT_MS", "15000") |> String.to_integer(),
  git_timeout_binary: System.get_env("PTC_GIT_TIMEOUT_BINARY"),
  external_pr_command_timeout_ms:
    System.get_env("PTC_EXTERNAL_PR_COMMAND_TIMEOUT_MS", "180000") |> String.to_integer(),
  git_diff_max_bytes: System.get_env("PTC_GIT_DIFF_MAX_BYTES", "50000000") |> String.to_integer(),
  git_max_commits: System.get_env("PTC_GIT_MAX_COMMITS", "100") |> String.to_integer(),
  git_max_changed_paths:
    System.get_env("PTC_GIT_MAX_CHANGED_PATHS", "100") |> String.to_integer(),
  git_max_blob_bytes: System.get_env("PTC_GIT_MAX_BLOB_BYTES", "10000000") |> String.to_integer(),
  git_max_total_blob_bytes:
    System.get_env("PTC_GIT_MAX_TOTAL_BLOB_BYTES", "50000000") |> String.to_integer(),
  git_memory_limit_binary: System.get_env("PTC_GIT_MEMORY_LIMIT_BINARY"),
  git_memory_limit_bytes:
    System.get_env("PTC_GIT_MEMORY_LIMIT_BYTES", "268435456") |> String.to_integer(),
  implementation_agent_kind: System.get_env("PTC_IMPLEMENTATION_AGENT_KIND", "codex"),
  implementation_agent_args:
    System.get_env(
      "PTC_IMPLEMENTATION_AGENT_ARGS",
      "--dangerously-bypass-approvals-and-sandbox"
    )
    |> OptionParser.split(),
  implementation_agent_start_timeout_ms:
    System.get_env("PTC_IMPLEMENTATION_AGENT_START_TIMEOUT_MS", "60000")
    |> String.to_integer(),
  implementation_agent_publishes_pr: implementation_agent_publishes_pr,
  implementation_test_command: System.get_env("PTC_IMPLEMENTATION_TEST_COMMAND"),
  manager_enabled: System.get_env("PTC_CODEX_MANAGER_ENABLED") == "true",
  manager_concurrency:
    System.get_env("PTC_CODEX_MANAGER_CONCURRENCY", "1") |> String.to_integer(),
  codex_binary: System.get_env("PTC_CODEX_BINARY", "codex"),
  codex_run_as_user: System.get_env("PTC_CODEX_RUN_AS_USER"),
  manager_output_dir: System.get_env("PTC_CODEX_OUTPUT_DIR"),
  manager_timeout_ms:
    System.get_env("PTC_CODEX_MANAGER_TIMEOUT_MS", "120000") |> String.to_integer()

if worktree_root = System.get_env("PTC_WORKTREE_ROOT") do
  config :ptc_manager, :worktree_root, worktree_root
end

if config_env() == :test do
  config :ptc_manager,
    dispatch_enabled: false,
    agent_actions_enabled: false,
    publication_enabled: false,
    pr_reconcile_enabled: false,
    worktree_reconcile_interval_ms: 0
end

if config_env() == :prod do
  raw_admin_password = System.get_env("PTC_MANAGER_PASSWORD")

  admin_password =
    if is_binary(raw_admin_password) and byte_size(String.trim(raw_admin_password)) >= 16 do
      raw_admin_password
    else
      raise "environment variable PTC_MANAGER_PASSWORD must contain at least 16 nonblank characters"
    end

  config :ptc_manager, :admin_password, admin_password

  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/ptc_manager/ptc_manager.db
      """

  config :ptc_manager, PtcManager.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :ptc_manager, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ptc_manager, PtcManagerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Tailscale Serve proxies to this loopback-only listener.
      ip: {127, 0, 0, 1},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ptc_manager, PtcManagerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ptc_manager, PtcManagerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
