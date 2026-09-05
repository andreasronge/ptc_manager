defmodule PtcManager.Repo.Migrations.UseSolForDefaultReviewers do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE execution_profiles
    SET reviewer_model = 'gpt-5.6-sol', reviewer_effort = 'xhigh',
        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE name IN ('small', 'standard', 'strong')
      AND reviewer_kind = 'codex'
      AND reviewer_model = 'gpt-6-astra'
      AND reviewer_effort IS NULL
    """)
  end

  # Profiles are editable configuration. Rolling code back must not undo a
  # maintainer's model choice or change any job's frozen execution settings.
  def down, do: :ok
end
