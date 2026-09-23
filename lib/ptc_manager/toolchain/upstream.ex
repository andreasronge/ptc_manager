defmodule PtcManager.Toolchain.Upstream do
  @moduledoc "Read-only, bounded checks for the deployed toolchain's upstream releases."

  alias PtcManager.Repo
  alias PtcManager.Toolchain.Check
  alias PtcManager.Toolchain

  @packages %{
    "codex" => "@openai/codex",
    "claude_code" => "@anthropic-ai/claude-code",
    "pnpm" => "pnpm"
  }
  @version ~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9.-]+)?\z/
  @digest ~r/\A[0-9a-f]{64}\z/
  @updatable Map.keys(@packages) ++ ~w(node herdr mise cursor_agent)
  @supported @updatable ++ ~w(erlang elixir)

  def supported, do: @supported
  def updatable?(program), do: program in @updatable

  def list do
    Check
    |> Repo.all()
    |> Map.new(&{&1.program, &1})
  end

  def check(program) when program in @supported do
    result = fetch(program)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs =
      case result do
        {:ok, data} ->
          Map.merge(data, %{program: program, status: "ok", error: nil, checked_at: now})

        {:error, reason} ->
          %{
            program: program,
            version: nil,
            digest: nil,
            protocol: nil,
            status: "failed",
            error: inspect(reason),
            checked_at: now
          }
      end

    %Check{}
    |> Check.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace, [:version, :digest, :protocol, :status, :error, :checked_at]},
      conflict_target: :program
    )

    case result do
      {:ok, %{version: version}} -> {:ok, version}
      error -> error
    end
  end

  def check(_program), do: {:error, :unsupported_program}

  defp fetch(program) when is_map_key(@packages, program) do
    package = Map.fetch!(@packages, program) |> URI.encode_www_form()
    url = "https://registry.npmjs.org/#{package}/latest"
    fetcher = Application.get_env(:ptc_manager, :toolchain_upstream_fetcher, __MODULE__)

    with {:ok, %{"version" => version}} <- fetcher.get(url),
         true <- is_binary(version) and Regex.match?(@version, version) do
      {:ok, %{version: version}}
    else
      false -> {:error, :invalid_upstream_version}
      {:ok, _} -> {:error, :invalid_upstream_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch("node") do
    fetcher = fetcher()
    pinned = Toolchain.pinned()["node"]

    with {:ok, current} <- Version.parse(pinned),
         {:ok, releases} when is_list(releases) <-
           fetcher.get("https://nodejs.org/dist/index.json"),
         versions <-
           Enum.flat_map(releases, fn
             %{"version" => "v" <> version} ->
               case Version.parse(version) do
                 {:ok, parsed} when parsed.major == current.major -> [{parsed, version}]
                 _ -> []
               end

             _ ->
               []
           end),
         [{_parsed, version} | _] <- Enum.sort_by(versions, &elem(&1, 0), {:desc, Version}) do
      {:ok, %{version: version}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_upstream_response}
    end
  end

  defp fetch("herdr") do
    with {:ok,
          %{"version" => version, "protocol" => protocol, "sha256" => %{"linux-x86_64" => digest}}} <-
           fetcher().get("https://herdr.dev/latest.json"),
         true <-
           Regex.match?(@version, version) and is_integer(protocol) and protocol > 0 and
             Regex.match?(@digest, digest) do
      {:ok, %{version: version, protocol: protocol, digest: digest}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_upstream_response}
    end
  end

  defp fetch("mise") do
    with {:ok, %{"tag_name" => "v" <> version, "assets" => assets}} when is_list(assets) <-
           fetcher().get("https://api.github.com/repos/jdx/mise/releases/latest"),
         true <- Regex.match?(@version, version),
         true <- Enum.any?(assets, &(&1["name"] == "SHASUMS256.txt")),
         {:ok, body} <-
           fetcher().body(
             "https://github.com/jdx/mise/releases/download/v#{version}/SHASUMS256.txt"
           ),
         [digest] <-
           Regex.run(
             ~r/^([0-9a-f]{64})\s+\.\/mise-v#{Regex.escape(version)}-linux-x64$/m,
             body,
             capture: :all_but_first
           ) do
      {:ok, %{version: version, digest: digest}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_upstream_response}
    end
  end

  defp fetch("cursor_agent") do
    with {:ok, script} <- fetcher().body("https://cursor.com/install"),
         [version] <-
           Regex.run(
             ~r/DOWNLOAD_URL="https:\/\/downloads\.cursor\.com\/lab\/([0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]+)\/\$\{OS\}\/\$\{ARCH\}\/agent-cli-package\.tar\.gz"/,
             script,
             capture: :all_but_first
           ),
         {:ok, digest} <-
           fetcher().archive_digest(
             "https://downloads.cursor.com/lab/#{version}/linux/x64/agent-cli-package.tar.gz"
           ),
         true <- Regex.match?(@digest, digest) do
      {:ok, %{version: version, digest: digest}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_upstream_response}
    end
  end

  defp fetch("erlang") do
    with {:ok, %{"tag_name" => "OTP-" <> version}} <-
           fetcher().get("https://api.github.com/repos/erlang/otp/releases/latest"),
         true <- Regex.match?(@version, version) do
      {:ok, %{version: version}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_upstream_response}
    end
  end

  defp fetch("elixir") do
    with {:ok, %{"tag_name" => "v" <> version}} <-
           fetcher().get("https://api.github.com/repos/elixir-lang/elixir/releases/latest"),
         true <- Regex.match?(@version, version) do
      {:ok, %{version: version}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_upstream_response}
    end
  end

  defp fetcher, do: Application.get_env(:ptc_manager, :toolchain_upstream_fetcher, __MODULE__)

  def get(url) do
    with {:ok, body} <- body(url) do
      Jason.decode(body)
    end
  end

  def body(url) do
    options = [
      timeout: 10_000,
      connect_timeout: 5_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    headers = [{~c"user-agent", ~c"ptc_manager"}]

    case :httpc.request(:get, {String.to_charlist(url), headers}, options, body_format: :binary) do
      {:ok, {{_version, 200, _message}, _headers, body}} when byte_size(body) <= 2_000_000 ->
        {:ok, body}

      {:ok, {{_version, status, _message}, _headers, _body}} ->
        {:error, {:upstream_http_error, status}}

      {:error, reason} ->
        {:error, {:upstream_transport_error, reason}}
    end
  end

  def archive_digest(url) do
    case System.find_executable("curl") do
      nil -> {:error, :curl_unavailable}
      curl -> download_archive_digest(curl, url)
    end
  end

  defp download_archive_digest(curl, url) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    directory = Path.join(System.tmp_dir!(), "ptc-cursor-check-#{suffix}")
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    path = Path.join(directory, "archive.tar.gz")

    try do
      case System.cmd(
             curl,
             [
               "--fail",
               "--silent",
               "--show-error",
               "--location",
               "--max-time",
               "180",
               "--max-filesize",
               "250000000",
               "--output",
               path,
               url
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          with {:ok, %{size: size}} when size <= 250_000_000 <- File.stat(path),
               {:ok, digest} <- File.open(path, [:read, :binary], &hash_archive/1) do
            {:ok, digest}
          else
            _ -> {:error, :cursor_archive_unavailable}
          end

        {_output, _status} ->
          {:error, :cursor_archive_unavailable}
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp hash_archive(file), do: hash_archive(file, :crypto.hash_init(:sha256))

  defp hash_archive(file, state) do
    case IO.binread(file, 1_048_576) do
      :eof -> state |> :crypto.hash_final() |> Base.encode16(case: :lower)
      {:error, _reason} -> raise "cursor archive could not be read"
      chunk -> hash_archive(file, :crypto.hash_update(state, chunk))
    end
  end
end
