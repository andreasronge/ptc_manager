defmodule PtcManager.DailyDigestsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.DailyDigests
  alias PtcManager.DailyDigests.DailyDigest
  alias PtcManager.DailyDigests.Scheduler
  alias PtcManager.MaintainerActions.ActionAdapter
  alias PtcManager.Operations.AgentAction
  alias PtcManager.Repo

  setup do
    previous = %{
      enabled: Application.get_env(:ptc_manager, :daily_digest_enabled),
      actions_enabled: Application.get_env(:ptc_manager, :agent_actions_enabled),
      hour: Application.get_env(:ptc_manager, :daily_digest_hour),
      time_zone: Application.get_env(:ptc_manager, :daily_digest_time_zone),
      interval: Application.get_env(:ptc_manager, :daily_digest_interval_ms)
    }

    Application.put_env(:ptc_manager, :daily_digest_enabled, true)
    Application.put_env(:ptc_manager, :agent_actions_enabled, true)
    Application.put_env(:ptc_manager, :daily_digest_hour, 2)
    Application.put_env(:ptc_manager, :daily_digest_time_zone, "Europe/Stockholm")
    Application.put_env(:ptc_manager, :daily_digest_interval_ms, 60_000)

    on_exit(fn ->
      restore_env(:daily_digest_enabled, previous.enabled)
      restore_env(:agent_actions_enabled, previous.actions_enabled)
      restore_env(:daily_digest_hour, previous.hour)
      restore_env(:daily_digest_time_zone, previous.time_zone)
      restore_env(:daily_digest_interval_ms, previous.interval)
    end)

    :ok
  end

  test "queues exactly the previous Stockholm day and is idempotent" do
    repository = repository_fixture(%{github_owner: "andreas", github_name: "runner"})
    now = ~U[2026-08-31 00:30:00Z]

    assert {:ok, [digest]} = DailyDigests.enqueue_due(now)
    assert digest.repository_id == repository.id
    assert digest.digest_date == ~D[2026-08-30]
    assert digest.window_started_at == ~U[2026-08-29 22:00:00.000000Z]
    assert digest.window_ended_at == ~U[2026-08-30 22:00:00.000000Z]
    assert digest.time_zone == "Europe/Stockholm"
    assert digest.agent_action.action_key == "daily_digest"
    assert digest.agent_action.target_type == "daily_digest"
    assert digest.agent_action.state == "queued"
    assert digest.agent_action.actor == "scheduler"
    assert digest.agent_action.prompt =~ ~s(date="2026-08-30")
    assert digest.agent_action.prompt =~ ~s(github_access="none")

    assert {:ok, [same_digest]} = DailyDigests.enqueue_due(now)
    assert same_digest.id == digest.id
    assert Repo.aggregate(DailyDigest, :count) == 1
    assert Repo.aggregate(AgentAction, :count) == 1
  end

  test "does not queue before the configured local hour or backfill older days" do
    repository_fixture()

    assert {:ok, []} = DailyDigests.enqueue_due(~U[2026-08-30 23:30:00Z])
    assert Repo.aggregate(DailyDigest, :count) == 0

    assert {:ok, [digest]} = DailyDigests.enqueue_due(~U[2026-08-31 00:30:00Z])
    assert digest.digest_date == ~D[2026-08-30]
    oldest_allowed = ~D[2026-08-30]
    refute Repo.exists?(from d in DailyDigest, where: d.digest_date < ^oldest_allowed)
  end

  test "does not schedule when the action consumer is disabled" do
    repository_fixture()
    Application.put_env(:ptc_manager, :agent_actions_enabled, false)

    assert {:ok, []} = DailyDigests.enqueue_due(~U[2026-08-31 00:30:00Z])
    assert Repo.aggregate(DailyDigest, :count) == 0
  end

  test "uses local midnight boundaries across daylight-saving time" do
    repository_fixture()

    assert {:ok, [digest]} = DailyDigests.enqueue_due(~U[2026-03-30 00:30:00Z])
    assert digest.digest_date == ~D[2026-03-29]
    assert digest.window_started_at == ~U[2026-03-28 23:00:00.000000Z]
    assert digest.window_ended_at == ~U[2026-03-29 22:00:00.000000Z]
    assert DateTime.diff(digest.window_ended_at, digest.window_started_at, :hour) == 23
  end

  test "resolves a daylight-saving gap that begins at midnight" do
    repository_fixture()
    Application.put_env(:ptc_manager, :daily_digest_time_zone, "America/Santiago")

    assert {:ok, [digest]} = DailyDigests.enqueue_due(~U[2026-09-07 06:00:00Z])
    assert digest.digest_date == ~D[2026-09-06]
    assert digest.window_started_at == ~U[2026-09-06 04:00:00.000000Z]
    assert digest.window_ended_at == ~U[2026-09-07 03:00:00.000000Z]
    assert DateTime.diff(digest.window_ended_at, digest.window_started_at, :hour) == 23
  end

  test "publishes only the matching action and exact requested window" do
    repository_fixture()
    assert {:ok, [digest]} = DailyDigests.enqueue_due(~U[2026-08-31 00:30:00Z])

    result = valid_result(digest)
    wrong_window = Map.put(result, "window_started_at", "2026-08-29T21:00:00.000000Z")

    assert {:error, :daily_digest_window_mismatch} =
             DailyDigests.publish(digest.agent_action, wrong_window)

    assert {:ok, published} = DailyDigests.publish(digest.agent_action, result)
    assert published.title == "A steadier build day"
    assert published.change_count == 2
    assert published.pull_request_numbers == %{"numbers" => [1713, 1716]}
    assert published.source_head_sha == String.duplicate("a", 40)
    assert DailyDigests.published?(published)

    assert {:error, :daily_digest_already_published} =
             DailyDigests.publish(digest.agent_action, result)
  end

  test "validates the constrained daily output contract" do
    result = %{
      "status" => "published",
      "title" => "A steadier build day",
      "summary" => "Two changes made build feedback clearer.",
      "markdown" => "## Fixed\n\nBuild errors now explain the missing tool.",
      "window_started_at" => "2026-08-29T22:00:00Z",
      "window_ended_at" => "2026-08-30T22:00:00Z",
      "source_head_sha" => String.duplicate("b", 40),
      "change_count" => 2,
      "pull_request_numbers" => [1713, 1716]
    }

    assert :ok = ActionAdapter.validate_result(result, "daily_digest")

    assert {:error, :invalid_daily_digest_output} =
             result
             |> Map.put("pull_request_numbers", [1716, 1713])
             |> ActionAdapter.validate_result("daily_digest")

    assert {:error, :invalid_daily_digest_output} =
             result
             |> Map.merge(%{"status" => "no-changes", "change_count" => 2})
             |> ActionAdapter.validate_result("daily_digest")

    assert {:error, :invalid_daily_digest_output} =
             result
             |> Map.put("change_count", 101)
             |> ActionAdapter.validate_result("daily_digest")
  end

  test "Codex output schema leaves uniqueness enforcement to application validation" do
    schema_path =
      Application.app_dir(:ptc_manager, "priv/codex/daily_digest_output.schema.json")

    assert {:ok, schema} = schema_path |> File.read!() |> Jason.decode()
    refute Map.has_key?(schema["properties"]["pull_request_numbers"], "uniqueItems")
  end

  test "scheduler falls back to a safe interval if runtime configuration is invalid" do
    Application.put_env(:ptc_manager, :daily_digest_interval_ms, 0)
    assert Scheduler.interval() == 60_000

    Application.put_env(:ptc_manager, :daily_digest_interval_ms, -1)
    assert Scheduler.interval() == 60_000

    Application.put_env(:ptc_manager, :daily_digest_interval_ms, 5_000)
    assert Scheduler.interval() == 5_000
  end

  defp valid_result(digest) do
    %{
      "status" => "published",
      "title" => "A steadier build day",
      "summary" => "Two changes made build feedback clearer.",
      "markdown" => "## Fixed\n\nBuild errors now explain the missing tool.",
      "window_started_at" => DateTime.to_iso8601(digest.window_started_at),
      "window_ended_at" => DateTime.to_iso8601(digest.window_ended_at),
      "source_head_sha" => String.duplicate("a", 40),
      "change_count" => 2,
      "pull_request_numbers" => [1713, 1716]
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
