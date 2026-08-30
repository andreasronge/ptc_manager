defmodule PtcManager.Repo.Migrations.AddRequiredReviewCountToJobs do
  use Ecto.Migration

  def up do
    alter table(:jobs) do
      add :required_review_count, :integer
    end

    execute("""
    UPDATE jobs
    SET required_review_count = #{legacy_review_count_sql()}
    WHERE required_review_count IS NULL
    """)
  end

  def down do
    alter table(:jobs) do
      remove :required_review_count
    end
  end

  defp legacy_review_count_sql do
    case System.get_env("PTC_REQUIRED_PRE_PR_REVIEWS") do
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {count, ""} when count in 0..10 -> count |> min(3) |> Integer.to_string()
          _invalid -> repository_review_count_sql()
        end

      _missing ->
        repository_review_count_sql()
    end
  end

  defp repository_review_count_sql do
    """
    COALESCE(
      (
        SELECT CASE
          WHEN repositories.required_pre_pr_reviews < 0 THEN 0
          WHEN repositories.required_pre_pr_reviews > 3 THEN 3
          ELSE repositories.required_pre_pr_reviews
        END
        FROM repositories
        WHERE repositories.id = jobs.repository_id
      ),
      2
    )
    """
  end
end
