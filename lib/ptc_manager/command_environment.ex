defmodule PtcManager.CommandEnvironment do
  @moduledoc "Builds scrubbed child-process environments and optional OS-user commands."

  @allowed_environment ~w(
    CODEX_HOME HOME USER LOGNAME PATH LANG LC_ALL LC_CTYPE
    TMPDIR TEMP TMP XDG_CONFIG_HOME XDG_CACHE_HOME
    SSL_CERT_FILE SSL_CERT_DIR HTTP_PROXY HTTPS_PROXY NO_PROXY
  )

  def scrub(environment \\ System.get_env()) do
    allowed =
      environment
      |> Map.take(@allowed_environment)
      |> drop_release_path(environment)

    environment
    |> Map.new(fn {key, _value} -> {key, nil} end)
    |> Map.merge(allowed)
    |> Map.to_list()
  end

  # A release's erlexec puts its bundled ERTS and `bin` first on PATH, so a
  # child running the host's `elixir` or `mix` would start the release's `erl`
  # and fail to boot.
  defp drop_release_path(%{"PATH" => path} = allowed, environment) do
    roots =
      environment
      |> Map.take(["ROOTDIR", "RELEASE_ROOT"])
      |> Map.values()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map(&String.trim_trailing(&1, "/"))

    entries =
      path
      |> String.split(":")
      |> Enum.reject(fn entry ->
        Enum.any?(roots, &(entry == &1 or String.starts_with?(entry, &1 <> "/")))
      end)

    %{allowed | "PATH" => Enum.join(entries, ":")}
  end

  defp drop_release_path(allowed, _environment), do: allowed

  def command(binary, args, run_as_user)
      when is_binary(run_as_user) and run_as_user != "" do
    {"/usr/bin/sudo", ["-n", "-H", "-u", run_as_user, "--", binary | args]}
  end

  def command(binary, args, _run_as_user), do: {binary, args}
end
