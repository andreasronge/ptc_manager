defmodule PtcManager.HealthSnapshotEvidenceTest do
  use ExUnit.Case, async: true

  alias PtcManager.HealthSnapshotEvidence

  @now ~U[2026-09-06 12:00:00Z]

  test "accepts a snapshot inside its declared freshness budget" do
    assert {:ok, snapshot} = validate(%{"captured_at" => "2026-09-06T11:30:00Z"})
    assert snapshot["freshness_budget_seconds"] == 3600
  end

  test "rejects evidence that will expire before the authorized analysis can finish" do
    snapshot = Map.put(valid_snapshot(), "captured_at", "2026-09-06T11:30:00Z")

    assert {:ok, _snapshot} = HealthSnapshotEvidence.validate_for(snapshot, 1800, @now)

    assert {:error, :health_snapshot_expired} =
             HealthSnapshotEvidence.validate_for(snapshot, 1801, @now)
  end

  test "rejects missing, malformed, future-dated, and expired evidence" do
    assert {:error, :health_snapshot_missing} = HealthSnapshotEvidence.read("/missing", @now)
    assert {:error, :health_snapshot_malformed} = validate("not json")

    assert {:error, :health_snapshot_future_dated} =
             validate(%{"captured_at" => "2026-09-06T12:05:01Z"})

    assert {:error, :health_snapshot_expired} =
             validate(%{"captured_at" => "2026-09-06T10:59:59Z"})
  end

  test "rejects a fresh object without the required runtime sections" do
    path = Path.join(System.tmp_dir!(), "incomplete-health-#{System.unique_integer([:positive])}")

    File.write!(
      path,
      Jason.encode!(%{
        "captured_at" => "2026-09-06T11:30:00Z",
        "freshness_budget_seconds" => 3600
      })
    )

    assert {:error, :health_snapshot_malformed} = HealthSnapshotEvidence.read(path, @now)
    File.rm!(path)
  end

  defp validate(value) do
    path = Path.join(System.tmp_dir!(), "health-evidence-#{System.unique_integer([:positive])}")

    snapshot =
      if is_map(value) do
        Map.merge(valid_snapshot(), value)
      else
        value
      end

    body =
      if is_binary(snapshot),
        do: snapshot,
        else: Jason.encode!(snapshot)

    File.write!(path, body)
    result = HealthSnapshotEvidence.read(path, @now)
    File.rm!(path)
    result
  end

  defp valid_snapshot do
    %{
      "captured_at" => "2026-09-06T11:30:00Z",
      "freshness_budget_seconds" => 3600,
      "capacity_settings" => [],
      "live_agent_runs" => [],
      "live_agent_actions" => [],
      "live_resource_operations" => [],
      "recent_resource_operations" => [],
      "live_jobs" => [],
      "service_log_volume" => %{
        "window" => "-6 hours",
        "line_limit" => 10_000,
        "at_limit" => false,
        "diagnostic_at_limit" => false,
        "total_lines" => 0,
        "session_noise_lines" => 0,
        "error_lines" => 0
      }
    }
  end
end
