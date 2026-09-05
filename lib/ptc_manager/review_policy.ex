defmodule PtcManager.ReviewPolicy do
  @moduledoc "Resolves the bounded independent-review count for implementation jobs."

  @maximum 100

  def default_count(repository) do
    (repository.required_pre_pr_reviews ||
       Application.get_env(:ptc_manager, :required_pre_pr_reviews_default, 2))
    |> normalize()
  end

  def job_count(job, repository) do
    (job.required_review_count || default_count(repository))
    |> normalize()
  end

  def normalize(count) when is_integer(count), do: count |> max(0) |> min(@maximum)
  def normalize(_count), do: 2
end
