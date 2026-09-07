defmodule PtcManager.Repo.Migrations.CaptureDeliveryTransitions do
  use Ecto.Migration

  @jobs ~w(state review_state review_resume_mode review_resume_expires_at stop_reported_at stop_acknowledged_at last_error)
  @pubs ~w(state pr_state draft checks_state mergeability remote_head_sha)
  def up do
    create table(:delivery_events) do
      add :job_id, references(:jobs, on_delete: :delete_all), null: false
      add :before_state, :map
      add :after_state, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:delivery_events, [:job_id, :id])
    # Capture data, not lane policy: report projections reuse DeliveryLane.
    # Triggers also cover the fenced UPDATE ... WHERE paths using update_all.
    for {table, fields} <- [{"jobs", @jobs}, {"pr_publications", ["job_id" | @pubs]}],
        action <- ["insert", "update"] do
      owner = if table == "jobs", do: "NEW.id", else: "NEW.job_id"
      change = Enum.map_join(fields, " OR ", &"OLD.#{&1} IS NOT NEW.#{&1}")

      when_sql =
        if action == "update",
          do: "(#{change}) AND #{owner} IS NOT NULL",
          else: "#{owner} IS NOT NULL"

      before = if action == "insert", do: "NULL", else: snapshot(table, "OLD")

      execute """
      CREATE TRIGGER delivery_#{table}_#{action}
      AFTER #{String.upcase(action)} ON #{table}
      WHEN #{when_sql}
      BEGIN
        INSERT INTO delivery_events(job_id,before_state,after_state,inserted_at)
        VALUES(#{owner},#{before},#{snapshot(table, "NEW")},strftime('%Y-%m-%dT%H:%M:%f000Z','now'));
      END
      """
    end
  end

  def down do
    for table <- ["jobs", "pr_publications"],
        action <- ["insert", "update"],
        do: execute("DROP TRIGGER delivery_#{table}_#{action}")

    drop table(:delivery_events)
  end

  defp object(prefix, fields),
    do: "json_object(" <> Enum.map_join(fields, ",", &"'#{&1}',#{prefix}.#{&1}") <> ")"

  defp snapshot("jobs", prefix),
    do:
      "json_object('job',#{object(prefix, @jobs)},'publication',json((SELECT #{object("p", @pubs)} FROM pr_publications p WHERE p.job_id=#{prefix}.id)))"

  defp snapshot("pr_publications", prefix),
    do:
      "json_object('job',json((SELECT #{object("j", @jobs)} FROM jobs j WHERE j.id=#{prefix}.job_id)),'publication',#{object(prefix, @pubs)})"
end
