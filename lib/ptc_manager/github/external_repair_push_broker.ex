defmodule PtcManager.GitHub.ExternalRepairPushBroker do
  @moduledoc "Pushes a verified external repair through a credential-isolated broker."

  alias PtcManager.CommandEnvironment

  def push_external_repair(
        path,
        repository,
        publication,
        expected_sha,
        repaired_sha,
        required_base
      ) do
    push_with_worker_wrapper(
      path,
      repository,
      publication,
      expected_sha,
      repaired_sha,
      required_base
    )
  end

  defp push_with_worker_wrapper(
         path,
         _repository,
         publication,
         expected_sha,
         repaired_sha,
         required_base
       ) do
    wrapper =
      Application.get_env(
        :ptc_manager,
        :external_pr_push_wrapper,
        "/usr/local/bin/ptc-manager-external-push"
      )

    user =
      Application.get_env(:ptc_manager, :external_pr_push_run_as_user) ||
        Application.get_env(:ptc_manager, :agent_action_run_as_user)

    args = [
      path,
      publication.head_repository,
      publication.head_ref,
      expected_sha,
      repaired_sha,
      required_base || "",
      limit(:github_publish_bundle_max_bytes, 250_000_000),
      limit(:git_max_commits, 100),
      limit(:git_max_changed_paths, 100),
      limit(:git_max_blob_bytes, 10_000_000),
      limit(:git_max_total_blob_bytes, 50_000_000)
    ]

    {command, command_args} = CommandEnvironment.command(wrapper, args, user)

    timeout_binary =
      Application.get_env(:ptc_manager, :github_push_timeout_binary) || "/usr/bin/timeout"

    timeout_ms = Application.get_env(:ptc_manager, :github_push_timeout_ms, 60_000)
    timeout_seconds = max(div(timeout_ms + 999, 1_000), 1)

    bounded_args = [
      "--signal=TERM",
      "--kill-after=2s",
      "#{timeout_seconds}s",
      command
      | command_args
    ]

    case System.cmd(timeout_binary, bounded_args,
           env: CommandEnvironment.scrub(),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, 124} -> {:error, {:external_repair_push_timeout, bounded(output)}}
      {output, status} -> {:error, {:external_repair_push_failed, status, bounded(output)}}
    end
  rescue
    error -> {:error, {:external_repair_push_failed, error.__struct__}}
  end

  defp bounded(output), do: output |> String.trim() |> String.slice(-500, 500)
  defp limit(key, default), do: Application.get_env(:ptc_manager, key, default) |> to_string()
end
