defmodule PtcManager.Repo.Migrations.SurfaceDispatchFailures do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE jobs SET
      stop_report = json_object(
        'reason_code', 'environment_broken',
        'summary', 'PtcManager could not start the implementation.',
        'detail', substr(coalesce(last_error, 'Startup failed'), 1, 2000),
        'progress', 'none'),
      stop_reported_at = coalesce(ended_at, updated_at)
    WHERE state = 'failed' AND stop_reported_at IS NULL
      AND stop_acknowledged_at IS NULL
      AND EXISTS (SELECT 1 FROM audit_events a WHERE a.target_type = 'job'
        AND a.target_id = jobs.id AND a.action = 'job.dispatch_failed')
      AND EXISTS (SELECT 1 FROM issues i WHERE i.id = jobs.issue_id AND i.state = 'open')
      AND NOT EXISTS (SELECT 1 FROM jobs newer WHERE newer.issue_id = jobs.issue_id AND newer.id > jobs.id)
    """)
  end

  def down, do: :ok
end
