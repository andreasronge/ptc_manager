defmodule PtcManager.CommandEnvironment do
  @moduledoc "Builds scrubbed child-process environments and optional OS-user commands."

  @allowed_environment ~w(
    CODEX_HOME HOME USER LOGNAME PATH LANG LC_ALL LC_CTYPE
    TMPDIR TEMP TMP XDG_CONFIG_HOME XDG_CACHE_HOME
    SSL_CERT_FILE SSL_CERT_DIR HTTP_PROXY HTTPS_PROXY NO_PROXY
  )

  def scrub(environment \\ System.get_env()) do
    allowed = Map.take(environment, @allowed_environment)

    environment
    |> Map.new(fn {key, _value} -> {key, nil} end)
    |> Map.merge(allowed)
    |> Map.to_list()
  end

  def command(binary, args, run_as_user)
      when is_binary(run_as_user) and run_as_user != "" do
    {"/usr/bin/sudo", ["-n", "-H", "-u", run_as_user, "--", binary | args]}
  end

  def command(binary, args, _run_as_user), do: {binary, args}
end
