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

config :ptc_manager,
  github_read_token: System.get_env("GITHUB_READ_TOKEN"),
  repository_path: System.get_env("PTC_REPOSITORY_PATH"),
  github_sync_interval_ms: github_sync_interval_ms,
  herdr_sync_interval_ms: herdr_sync_interval_ms,
  herdr_session: System.get_env("PTC_HERDR_SESSION", "default"),
  herdr_binary: System.get_env("PTC_HERDR_BINARY", "herdr"),
  herdr_socket_path: System.get_env("PTC_HERDR_SOCKET_PATH"),
  herdr_timeout_ms: System.get_env("PTC_HERDR_TIMEOUT_MS", "15000") |> String.to_integer(),
  herdr_stale_after_ms:
    System.get_env("PTC_HERDR_STALE_AFTER_MS", "60000") |> String.to_integer(),
  manager_enabled: System.get_env("PTC_CODEX_MANAGER_ENABLED") == "true",
  manager_concurrency:
    System.get_env("PTC_CODEX_MANAGER_CONCURRENCY", "1") |> String.to_integer(),
  codex_binary: System.get_env("PTC_CODEX_BINARY", "codex"),
  codex_run_as_user: System.get_env("PTC_CODEX_RUN_AS_USER"),
  manager_output_dir: System.get_env("PTC_CODEX_OUTPUT_DIR"),
  manager_timeout_ms:
    System.get_env("PTC_CODEX_MANAGER_TIMEOUT_MS", "120000") |> String.to_integer()

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
