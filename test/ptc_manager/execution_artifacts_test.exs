defmodule PtcManager.ExecutionArtifactsTest do
  use PtcManager.DataCase, async: false
  alias PtcManager.Operations.AgentRun
  alias PtcManager.{Operations, ExecutionArtifacts}
  alias PtcManager.DailyDigests.Bundle

  defmodule FailingCapture do
    def run(_, _), do: {"temporary capture failure", 1}
  end

  defmodule RetryCapture do
    def run(_helper, _args), do: {"", Process.get(:capture_status, 1)}
    def run(["workspace", "close", "generic-workspace"]), do: {:ok, "closed"}
  end

  test "terminal generic actions retry archival without a source snapshot" do
    repository = repository_fixture()
    worker = worker_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    action =
      Repo.insert!(%PtcManager.Operations.AgentAction{
        repository_id: repository.id,
        action_key: "post_cancellation_note",
        target_type: "issue",
        target_id: 1,
        target_label: "issue",
        prompt: "task",
        actor: "maintainer",
        state: "done",
        requested_at: now
      })

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        agent_action_id: action.id,
        role: "implementer",
        state: "working",
        started_at: now,
        last_heartbeat_at: now,
        external_key: "default:generic-pane",
        provider_kind: "codex",
        herdr_workspace: "generic-workspace"
      })

    keys = [:execution_artifact_root, :execution_artifact_command, :generic_herdr_command]
    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:ptc_manager, key, value) end)
    end)

    Application.put_env(:ptc_manager, :execution_artifact_root, "/tmp/generic-archive-retry")
    Application.put_env(:ptc_manager, :execution_artifact_command, RetryCapture)
    Application.put_env(:ptc_manager, :generic_herdr_command, RetryCapture)

    assert {:error, :provider_session_archival_failed} =
             ExecutionArtifacts.cleanup_terminal_once()

    Process.put(:capture_status, 0)
    assert :ok = ExecutionArtifacts.cleanup_terminal_once()
    assert :ok = ExecutionArtifacts.cleanup_terminal_once()
    assert Repo.get!(AgentRun, run.id).provider_sessions_archived
  end

  test "continuations preserve every exact provider session in the reused run" do
    first =
      AgentRun.changeset(%AgentRun{}, %{external_key: "default:first", provider_kind: "codex"})

    run = Ecto.Changeset.apply_changes(first)
    second = AgentRun.changeset(run, %{external_key: "default:second", provider_kind: "claude"})
    assert second.changes[:provider_sessions] == %{"first" => "codex", "second" => "claude"}
  end

  test "daily bundles index both continuation sessions and detect a missing latest capture" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")
    worker = worker_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "working",
        started_at: now,
        last_heartbeat_at: now,
        external_key: "default:first",
        provider_kind: "codex"
      })

    run =
      run
      |> AgentRun.changeset(%{external_key: "default:second", provider_kind: "claude"})
      |> Repo.update!()

    root = Path.join(System.tmp_dir!(), "session-history-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:ptc_manager, :execution_artifact_root)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :execution_artifact_root, previous)
      File.rm_rf!(root)
    end)

    Application.put_env(:ptc_manager, :execution_artifact_root, root)

    previous_command = Application.get_env(:ptc_manager, :execution_artifact_command)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :execution_artifact_command, previous_command)
    end)

    Application.put_env(:ptc_manager, :execution_artifact_command, FailingCapture)
    assert {:error, :provider_session_archival_failed} = ExecutionArtifacts.archive_run(run.id)

    paths =
      for {session, kind} <- run.provider_sessions do
        directory =
          Path.join([
            root,
            "repository-#{repository.id}",
            "job-#{job.id}",
            "agent-run-#{run.id}-#{ExecutionArtifacts.session_token(session)}"
          ])

        File.mkdir_p!(directory)
        File.write!(Path.join(directory, "session.jsonl"), session)

        File.write!(
          Path.join(directory, "manifest.json"),
          Jason.encode!(%{
            "kind" => "provider_session",
            "provider" => kind,
            "session_id" => session,
            "coverage" => "complete",
            "streams" => %{
              "session" => %{
                "path" => "session.jsonl",
                "bytes" => byte_size(session),
                "sha256" => ExecutionArtifacts.session_token(session),
                "coverage" => "complete"
              }
            }
          })
        )

        {session, directory}
      end
      |> Map.new()

    assert :ok = ExecutionArtifacts.archive_run(run.id)

    digest = %{id: 1, window_started_at: now, window_ended_at: now}

    evidence = %{
      "pull_requests" => %{"data" => [%{"attempts" => %{"data" => [%{"job_id" => job.id}]}}]}
    }

    assert {:ok, bundle} =
             Bundle.publish(repository, digest, evidence, %{}, %{action_id: 1, attempt: 1})

    assert length(bundle.manifest["execution_artifacts"]["data"]) == 2
    File.rm!(Path.join(paths["second"], "manifest.json"))

    assert {:ok, next} =
             Bundle.publish(repository, digest, evidence, %{}, %{action_id: 1, attempt: 2})

    assert "agent_run:#{run.id}-#{ExecutionArtifacts.session_token("second")}" in next.manifest[
             "execution_artifacts"
           ]["missing_source_ids"]
  end
end
