defmodule Mix.Tasks.Ptc.HerdrWorkspaceCanary do
  use Mix.Task

  @shortdoc "Checks Herdr worktree creation and repository setup locally"

  @moduledoc """
  Creates a disposable worktree through the configured local Herdr session,
  runs the exact checked-in repository setup script, prints phase timings, and
  removes the worktree and temporary branch. It never starts an AI agent.

      mix ptc.herdr_workspace_canary --repository /absolute/path/to/repository
      mix ptc.herdr_workspace_canary --session canary --repository "$PWD"

  Use `--base branch-or-sha` to select a source other than the repository's
  currently checked-out branch.
  """

  alias PtcManager.Dispatch.HerdrAdapter
  alias PtcManager.Herdr.Command
  alias PtcManager.Operations.Job
  alias PtcManager.Repository.{Checkout, WorkspaceSetup}

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [repository: :string, base: :string, session: :string])

    if positional != [] or invalid != [], do: usage_error()

    with_session(Keyword.get(options, :session), fn -> run_canary(options) end)
  end

  defp run_canary(options) do
    repository =
      options
      |> Keyword.get(:repository)
      |> required_repository()

    base =
      Keyword.get_lazy(options, :base, fn -> git!(repository, ["branch", "--show-current"]) end)

    base = if base == "", do: "HEAD", else: base
    id = System.unique_integer([:positive, :monotonic])
    branch = "ptc-manager/issue-0-job-#{id}"
    worktree = Path.join(System.tmp_dir!(), "ptc-manager-herdr-canary-#{id}")
    command = Application.get_env(:ptc_manager, :workspace_canary_herdr_command, Command)

    preflight!(command)

    started = System.monotonic_time(:millisecond)

    created =
      command.run([
        "worktree",
        "create",
        "--cwd",
        repository,
        "--branch",
        branch,
        "--base",
        base,
        "--path",
        worktree,
        "--label",
        "workspace-setup-canary",
        "--no-focus"
      ])

    case created do
      {:ok, output} ->
        creation_ms = max(System.monotonic_time(:millisecond) - started, 0)

        with {:ok, workspace, _pane} <- HerdrAdapter.decode_worktree(output) do
          try do
            run_setup!(worktree, branch, id, creation_ms)
          after
            cleanup!(command, workspace, repository, branch)
          end
        else
          {:error, reason} ->
            Mix.raise("Herdr returned an unexpected worktree response: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("Herdr could not create the canary worktree: #{inspect(reason)}")
    end
  end

  defp run_setup!(worktree, branch, id, creation_ms) do
    job = %Job{id: id, issue_id: 0, branch_name: branch}

    case WorkspaceSetup.run(worktree, job) do
      {:ok, report} ->
        Mix.shell().info("Local Herdr workspace canary passed.")
        Mix.shell().info("Worktree creation: #{format_ms(creation_ms)}")
        Mix.shell().info("Repository setup: #{format_ms(report.duration_ms)}")
        Mix.shell().info("Script: #{report.script}")
        Mix.shell().info("Source: #{report.source_sha}")

        if report.output != "" do
          Mix.shell().info("\nSetup output:\n#{report.output}")
        end

      {:error, report} ->
        Mix.raise(
          "Repository setup failed after #{format_ms(report.duration_ms)}: " <>
            "#{inspect(report.error)}\n#{report.output}"
        )
    end
  end

  defp cleanup!(command, workspace, repository, branch) do
    case command.run(["worktree", "remove", "--workspace", workspace, "--force"]) do
      {:ok, _output} ->
        case System.cmd("git", ["-C", repository, "branch", "-D", branch], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> Mix.raise("Canary branch cleanup failed (#{status}): #{output}")
        end

      {:error, reason} ->
        Mix.raise(
          "Canary worktree cleanup failed; inspect #{workspace} before retrying: #{inspect(reason)}"
        )
    end
  end

  defp preflight!(command) do
    session = Application.get_env(:ptc_manager, :herdr_session, "default")

    case command.run(["status", "server"]) do
      {:ok, output} ->
        Mix.shell().info("Herdr session: #{session}")

        output
        |> String.trim()
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "socket:"))
        |> then(fn
          nil -> :ok
          socket -> Mix.shell().info("#{socket}")
        end)

      {:error, reason} ->
        Mix.raise("Herdr session #{inspect(session)} is not available: #{inspect(reason)}")
    end
  end

  defp with_session(nil, fun), do: fun.()

  defp with_session(session, fun) when is_binary(session) and session != "" do
    previous = Application.get_env(:ptc_manager, :herdr_session)
    Application.put_env(:ptc_manager, :herdr_session, session)

    try do
      fun.()
    after
      restore_session(previous)
    end
  end

  defp with_session(_session, _fun), do: usage_error()

  defp restore_session(nil), do: Application.delete_env(:ptc_manager, :herdr_session)
  defp restore_session(session), do: Application.put_env(:ptc_manager, :herdr_session, session)

  defp required_repository(nil), do: usage_error()

  defp required_repository(path) do
    path = Path.expand(path)

    with true <- File.dir?(path),
         {:ok, canonical_path} <- Checkout.canonical_directory(path),
         {:ok, top_level} <- git(path, ["rev-parse", "--show-toplevel"]),
         {:ok, canonical_top_level} <- Checkout.canonical_directory(top_level),
         true <- canonical_path == canonical_top_level do
      canonical_path
    else
      _failure -> Mix.raise("--repository must identify an absolute Git checkout root")
    end
  end

  defp git!(path, args) do
    case git(path, args) do
      {:ok, output} -> output
      {:error, output} -> Mix.raise("Git inspection failed: #{output}")
    end
  end

  defp git(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end

  defp usage_error do
    Mix.raise(
      "usage: mix ptc.herdr_workspace_canary --repository /absolute/repository " <>
        "[--base ref] [--session name]"
    )
  end

  defp format_ms(milliseconds) when milliseconds < 1_000, do: "#{milliseconds}ms"

  defp format_ms(milliseconds),
    do: :erlang.float_to_binary(milliseconds / 1_000, decimals: 1) <> "s"
end
